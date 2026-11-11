import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dlna_dart/dlna.dart';
import 'package:flutter/material.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/services/logging/logger.dart';

class RemotePlay {
  Future<void> castVideo(String video, {required String title}) async {
    final searcher = DLNAManager();
    final dlna = await searcher.start();
    StreamSubscription<Map<String, DLNADevice>>? subscription;
    final loggedDevices = <String>{};
    List<Widget> dlnaDevice = [];
    await KazumiDialog.show(builder: (BuildContext context) {
      return StatefulBuilder(builder: (context, setState) {
        return AlertDialog(
          title: const Text('远程投屏'),
          content: SingleChildScrollView(
            child: Column(
              children: dlnaDevice,
            ),
          ),
          actions: [
            const SizedBox(width: 20),
            TextButton(
              onPressed: () {
                KazumiDialog.dismiss();
              },
              child: Text(
                '退出',
                style: TextStyle(color: Theme.of(context).colorScheme.outline),
              ),
            ),
            TextButton(
                onPressed: () {
                  KazumiDialog.showToast(
                    message: '开始搜索',
                  );
                  // The device stream is single-subscription.
                  subscription ??= dlna.devices.stream.listen((deviceList) {
                    final tiles = <Widget>[];
                    deviceList.forEach((key, value) {
                      final castable = _supportsAVTransport(value);
                      if (loggedDevices.add(key)) {
                        KazumiLogger().i(
                            'RemotePlay: found ${value.info.friendlyName} ${value.info.deviceType} ${value.info.URLBase}${castable ? '' : ', skipped without AVTransport'}');
                      }
                      if (!castable) {
                        return;
                      }
                      final typeName = _deviceTypeName(value.info.deviceType);
                      tiles.add(ListTile(
                          leading: _deviceUPnPIcon(typeName),
                          title: Text(value.info.friendlyName),
                          subtitle: Text(typeName),
                          onTap: () async {
                            try {
                              KazumiDialog.showToast(
                                message: '尝试投屏至 ${value.info.friendlyName}',
                              );
                              await _castToDevice(value, video, title);
                            } catch (e) {
                              KazumiLogger().e(
                                  'RemotePlay: failed to cast to device',
                                  error: e);
                              KazumiDialog.showToast(
                                message: 'DLNA 异常: $e \n尝试重新进入 DLNA 投屏或切换设备',
                              );
                            }
                          }));
                    });
                    // Also rebuild when empty, so pruned devices disappear.
                    setState(() {
                      dlnaDevice = tiles;
                    });
                  });
                },
                child: Text(
                  '搜索',
                  style:
                      TextStyle(color: Theme.of(context).colorScheme.outline),
                )),
          ],
        );
      });
    }, onDismiss: () {
      subscription?.cancel();
      searcher.stop();
    });
  }

  static const String _avTransportType =
      'urn:schemas-upnp-org:service:AVTransport:1';

  /// 部分运营商定制机顶盒无法解析内联的 DIDL-Lite，收到 SetAVTransportURI
  /// 会直接断开连接。这里自行发送 SOAP 请求，DIDL 整体转义后再放入
  /// CurrentURIMetaData，这是与 dlna_dart 默认行为唯一的区别。
  Future<void> _castToDevice(
      DLNADevice device, String video, String title) async {
    final uri = Uri.parse(device.controlURL('AVTransport'));
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8);
    try {
      await _soapPost(client, uri, 'SetAVTransportURI',
          body: _setUriBody(video, title));
      await _soapPost(client, uri, 'Play', body: _playBody);
      final confirmed = await _confirmPlaying(client, uri, video);
      KazumiDialog.showToast(
        message: confirmed ? '投屏成功，电视正在播放' : '投屏指令已发送，请查看电视画面',
      );
    } finally {
      client.close(force: true);
    }
  }

  /// 这类机顶盒执行完指令后会直接断开连接、不回完整响应头，
  /// 响应读取阶段的 HttpException 不能当作投屏失败。
  Future<String> _soapPost(
      HttpClient client, Uri uri, String action,
      {required String body}) async {
    final request = await client.postUrl(uri);
    request.headers.set('SOAPAction', '"$_avTransportType#$action"');
    request.headers.set('Content-Type', 'text/xml');
    request.headers.set('Connection', 'close');
    final payload = utf8.encode(body);
    request.contentLength = payload.length;
    request.add(payload);
    try {
      final response =
          await request.close().timeout(const Duration(seconds: 15));
      final text = await response.transform(utf8.decoder).join();
      if (response.statusCode != HttpStatus.ok) {
        KazumiLogger()
            .i('RemotePlay: $action HTTP ${response.statusCode} $text');
      }
      return text;
    } on SocketException {
      rethrow; // 连不上才是真失败
    } on HttpException catch (e) {
      KazumiLogger().i('RemotePlay: $action 响应丢失（设备多半已执行）$e');
      return '';
    }
  }

  /// 以设备自己回报的 TrackURI 为准判断是否真的投上去了。
  Future<bool> _confirmPlaying(
      HttpClient client, Uri uri, String video) async {
    final probe = video.split('&').first;
    if (probe.isEmpty) {
      return false;
    }
    for (var attempt = 0; attempt < 3; attempt++) {
      await Future<void>.delayed(const Duration(seconds: 2));
      String text;
      try {
        text = await _soapPost(client, uri, 'GetPositionInfo',
            body: '<InstanceID>0</InstanceID>');
      } catch (e) {
        continue;
      }
      final match =
          RegExp('<TrackURI>(.*?)</TrackURI>', dotAll: true).firstMatch(text);
      if (match == null) {
        continue;
      }
      final track = _unescapeXml(match.group(1)!.trim());
      if (track.contains(probe)) {
        return true;
      }
    }
    return false;
  }

  String _unescapeXml(String value) => value
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&amp;', '&');

  String _setUriBody(String video, String title) {
    final didl = '<DIDL-Lite '
        'xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" '
        'xmlns:dc="http://purl.org/dc/elements/1.1/" '
        'xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" '
        'xmlns:dlna="urn:schemas-dlna-org:metadata-1-0/">'
        '<item id="id" parentID="0" restricted="0">'
        '<dc:title>${_escapeXml(title)}</dc:title>'
        '<upnp:artist>unknow</upnp:artist>'
        '<upnp:class>object.item.videoItem</upnp:class>'
        '<res protocolInfo="http-get:*:*:*">${_escapeXml(video)}</res>'
        '</item></DIDL-Lite>';
    return '<?xml version="1.0" encoding="utf-8" standalone="yes"?>'
        '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
        's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
        '<s:Body><u:SetAVTransportURI xmlns:u="$_avTransportType">'
        '<InstanceID>0</InstanceID>'
        '<CurrentURI>${_escapeXml(video)}</CurrentURI>'
        '<CurrentURIMetaData>${_escapeXml(didl)}</CurrentURIMetaData>'
        '</u:SetAVTransportURI></s:Body></s:Envelope>';
  }

  String get _playBody =>
      '<?xml version="1.0" encoding="utf-8" standalone="yes"?>'
      '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
      's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
      '<s:Body><u:Play xmlns:u="$_avTransportType">'
      '<InstanceID>0</InstanceID><Speed>1</Speed>'
      '</u:Play></s:Body></s:Envelope>';

  String _escapeXml(String value) => value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&#39;');

  // DLNADevice.controlURL resolves every cast request through this service.
  bool _supportsAVTransport(DLNADevice device) {
    return device.info.serviceList
        .any((service) => '${service['serviceId']}'.contains('AVTransport'));
  }

  String _deviceTypeName(String deviceType) {
    final parts = deviceType.split(':');
    return parts.length > 3 ? parts[3] : deviceType;
  }

  Icon _deviceUPnPIcon(String deviceType) {
    switch (deviceType) {
      case 'MediaRenderer':
        return const Icon(Icons.cast_connected);
      case 'MediaServer':
        return const Icon(Icons.cast_connected);
      case 'InternetGatewayDevice':
        return const Icon(Icons.router);
      case 'BasicDevice':
        return const Icon(Icons.device_hub);
      case 'DimmableLight':
        return const Icon(Icons.lightbulb);
      case 'WLANAccessPoint':
        return const Icon(Icons.lan);
      case 'WLANConnectionDevice':
        return const Icon(Icons.wifi_tethering);
      case 'Printer':
        return const Icon(Icons.print);
      case 'Scanner':
        return const Icon(Icons.scanner);
      case 'DigitalSecurityCamera':
        return const Icon(Icons.camera_enhance_outlined);
      default:
        return const Icon(Icons.question_mark);
    }
  }
}
