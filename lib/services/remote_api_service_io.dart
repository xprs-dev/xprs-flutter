/*
 * Native (dart:io) implementation of the XPRS remote-control HTTP API.
 * See remote_api_service.dart for the endpoint contract. Modelled on
 * xprs's LogApiService: binds InternetAddress.anyIPv4:<port>, dispatches
 * the /api/ paths, CORS-open, JSON in/out.
 */

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'xprs/xprs_archive.dart';
import 'xprs/xprs_bridge.dart';
import 'xprs/xprs_ingest.dart';
import 'xprs/xprs_lan.dart';
import 'xprs/xprs_publisher.dart';
import 'mesh/xblob_service.dart';
import '../connections/bluetooth/ble5_bus.dart';
import 'xprs/xprs_gossip.dart';
import 'xprs/xprs_group_ops.dart';
import 'xprs/xprs_groups.dart';
import 'xprs/xprs_graph.dart';
import 'mesh/mesh_courier.dart';
import 'mesh/mesh_custody.dart';
import 'xprs/xprs_forwarder.dart';
import 'xprs/xprs_airtime.dart';
import 'xprs/xprs_body.dart';
import 'xprs/xprs_receipt.dart';
import 'xprs/xprs_packet.dart';
import 'xprs/xprs_vocab.dart';

import 'package:flutter/material.dart';

import '../connections/bluetooth/ble_service.dart';
import '../connections/wifi_direct/wifi_direct_service.dart';
import 'wifi_direct/wifi_direct_coordinator.dart';
import 'mesh/mesh_bulk_spool.dart';
import 'mesh/mesh_service.dart';
import 'mesh/mesh_store.dart';
import 'mesh/mesh_table.dart';
import 'mesh/mesh_transfer_scheduler.dart';
import '../platform/platform.dart' as platform;
import '../profile/profile_service.dart';
import '../profile/storage_paths.dart';
import '../util/media_archive.dart';
import '../util/media_ref.dart';
import '../util/nostr_crypto.dart';
import '../wapp/geoui/widgets/media_view.dart' show sharedMediaArchive;
import '../wapp/background_wapp_manager.dart';
import '../wapp/shared_media_fetch.dart' show resolveSharedMedia;
import '../wapp/wapp_page.dart';
import 'blossom_server.dart';
import 'files/media_file_source.dart';
import 'i2p/i2p_service.dart';
import 'log_service.dart';
import 'reticulum/rns_service.dart';
import 'folders/folder_event.dart' show FolderShareType;
import 'preferences_service.dart';
import 'hero/hero_feed_service.dart';
import 'wapp_unread_service.dart';
import 'hero/hero_inbox.dart';
import 'hero/launcher_visibility.dart';
import 'torrent_service.dart';
import '../version.dart';
import 'update_mirror_service.dart';
import 'xprs/xprs_files.dart';
import 'update_service.dart';
import 'update_models.dart';
import 'update_native.dart';

/// Fixed RNS-over-WiFi-Direct port (the GO serves RNS here on 192.168.49.1).
const int kWfdRnsPort = 4965;

class RemoteApiService {
  RemoteApiService._();
  static final RemoteApiService instance = RemoteApiService._();

  /// Standard XPRS device-API port.
  static const int defaultPort = 3456;

  HttpServer? _server;
  int _port = defaultPort;
  GlobalKey<NavigatorState>? _navigatorKey;

  bool get running => _server != null;
  int get port => _port;

  /// Start the API server (idempotent). [navigatorKey] is the app's root
  /// navigator, used to open wapps on POST /api/launch.
  Future<void> start({int? port, GlobalKey<NavigatorState>? navigatorKey}) async {
    if (navigatorKey != null) _navigatorKey = navigatorKey;
    if (port != null) _port = port;
    if (_server != null) return;
    try {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, _port, shared: true);
      LogService.instance.add('RemoteApi: listening on 0.0.0.0:$_port');
      _server!.listen(_handle, onError: (e) {
        LogService.instance.add('RemoteApi: request error: $e');
      });
    } catch (e) {
      _server = null;
      LogService.instance.add('RemoteApi: bind failed on $_port: $e');
    }
  }

  Future<void> stop() async {
    final s = _server;
    _server = null;
    if (s != null) {
      try {
        await s.close(force: true);
      } catch (_) {}
      LogService.instance.add('RemoteApi: stopped');
    }
  }

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    res.headers.set('Access-Control-Allow-Origin', '*');
    res.headers.set('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
    res.headers.set('Access-Control-Allow-Headers', 'Content-Type');
    final path = req.uri.path;
    try {
      if (req.method == 'OPTIONS') {
        res.statusCode = HttpStatus.ok;
        await res.close();
        return;
      }
      if (req.method == 'GET' && (path == '/' || path == '/api/status')) {
        return _json(res, await _status());
      }
      if (req.method == 'GET' && (path == '/api/log' || path == '/api/logs')) {
        final n = int.tryParse(req.uri.queryParameters['n'] ?? '') ?? 200;
        return _json(res, {'lines': LogService.instance.tail(n)});
      }
      // --- dev/bench: drive the 1:1 GATT lane from the desk ---------------
      // These exist so the phone can be exercised as a station-facing GATT
      // endpoint without UI: dial a station, push a firmware image over
      // XBLOB, send one wire over the link. Plain HTTP on the device API,
      // like everything else here.
      if (req.method == 'POST' && path == '/api/dev/gattdial') {
        final mac = req.uri.queryParameters['mac'] ?? '';
        final call = req.uri.queryParameters['call'] ?? '';
        if (mac.isEmpty) return _json(res, {'ok': false, 'err': 'mac='});
        GattPeer.callsign = call;
        await Ble5Bus.instance.gattConnect(mac);
        return _json(res, {'ok': true, 'mac': mac, 'call': call});
      }
      if (req.method == 'POST' && path == '/api/dev/gattsend') {
        final wire = await utf8.decoder.bind(req).join();
        final send = MeshSessionManager.instance.hooks.clientSend;
        if (wire.isEmpty || send == null) {
          return _json(res, {'ok': false, 'err': 'no wire or no link'});
        }
        await send(Uint8List.fromList(utf8.encode(wire)));
        return _json(res, {'ok': true, 'bytes': wire.length});
      }
      if (req.method == 'POST' && path == '/api/dev/serveimage') {
        final sig = req.uri.queryParameters['sig'] ?? '';
        final shaHex = req.uri.queryParameters['sha'] ?? '';
        final chunks = <int>[];
        await for (final c in req) {
          chunks.addAll(c);
        }
        if (shaHex.length != 64 || chunks.isEmpty) {
          return _json(res, {'ok': false, 'err': 'sha= and body required'});
        }
        final sha = Uint8List(32);
        for (var i = 0; i < 32; i++) {
          sha[i] = int.parse(shaHex.substring(2 * i, 2 * i + 2), radix: 16);
        }
        XblobService.instance
            .serveImage(Uint8List.fromList(chunks), sha, sig85: sig);
        return _json(res, {'ok': true, 'size': chunks.length});
      }
      if (req.method == 'GET' && path == '/api/dev/gatt') {
        return _json(res, {
          'clientMtu': Ble5Bus.instance.clientMtu,
          'linkUp': Ble5Bus.instance.clientLinkUp,
          'serverMtu': Ble5Bus.instance.serverMtu,
          'blobActive': XblobService.instance.active,
          'peer': GattPeer.callsign,
        });
      }
      if (req.method == 'GET' && path == '/api/wapps') {
        return _json(res, {'wapps': await _listWapps()});
      }
      if (req.method == 'POST' && path == '/api/launch') {
        final body = await utf8.decoder.bind(req).join();
        Map<String, dynamic> data = {};
        if (body.trim().isNotEmpty) {
          final decoded = jsonDecode(body);
          if (decoded is Map<String, dynamic>) data = decoded;
        }
        final id = (data['wapp'] ?? data['id'] ?? data['name'] ?? '').toString();
        final ok = await _launch(id);
        return _json(res, {'ok': ok, 'wapp': id},
            status: ok ? HttpStatus.ok : HttpStatus.notFound);
      }
      // --- launcher hero (inspect the feed; publish a card as a wapp would) ---
      if (req.method == 'GET' && path == '/api/hero') {
        final items = HeroFeedService.instance.items.value;
        return _json(res, {
          // Whether the hero is refreshing at all: it is gated on the launcher
          // actually being on screen, so `visible:false` is the first thing to
          // check when the carousel looks stale.
          'visible': LauncherVisibility.instance.visible.value,
          'lastRefresh':
              HeroFeedService.instance.lastRefresh?.toIso8601String(),
          'items': [
            for (final i in items)
              {
                'id': i.id,
                'source': i.sourceId,
                'title': i.title,
                'author': i.authorName,
                'ageMinutes':
                    DateTime.now().difference(i.createdAt).inMinutes,
                'likes': i.likes,
                'replies': i.replies,
                'image': i.imageUrl,
              },
          ],
        });
      }
      // Exactly what a wapp's hal_msg_send({"type":"hero.publish", …}) does —
      // same HeroInbox entry point, same validation. Lets a hero card be tested
      // without shipping a wapp that publishes one.
      if (req.method == 'POST' && path == '/api/hero/publish') {
        final body = await utf8.decoder.bind(req).join();
        final decoded = jsonDecode(body);
        if (decoded is! Map<String, dynamic>) {
          return _json(res, {'error': 'expected a JSON object'},
              status: HttpStatus.badRequest);
        }
        final wapp = (decoded['wapp'] ?? 'debug').toString();
        final handled = HeroInbox.instance.handleMessage(wapp, {
          'type': decoded['type'] ?? 'hero.publish',
          if (decoded['replace'] != null) 'replace': decoded['replace'],
          if (decoded['items'] != null) 'items': decoded['items'],
          if (decoded['id'] != null) 'id': decoded['id'],
        });
        unawaited(HeroFeedService.instance.refresh());
        return _json(res, {'ok': handled, 'wapp': wapp});
      }
      // Same entry point a wapp's {"type":"unread"} message lands on. The dock
      // floats wapps with unread to the front, and that is otherwise only
      // testable by convincing a real wapp to receive a real message.
      if (req.method == 'POST' && path == '/api/unread') {
        final body = await utf8.decoder.bind(req).join();
        final decoded = jsonDecode(body);
        if (decoded is! Map<String, dynamic>) {
          return _json(res, {'error': 'expected a JSON object'},
              status: HttpStatus.badRequest);
        }
        final wapp = (decoded['wapp'] ?? '').toString();
        final count = (decoded['count'] as num?)?.toInt() ?? 0;
        if (wapp.isEmpty) {
          return _json(res, {'error': 'wapp is required'},
              status: HttpStatus.badRequest);
        }
        WappUnreadService.instance.setCount(wapp, count);
        return _json(res, {'ok': true, 'wapp': wapp, 'count': count});
      }
      // --- headless media / BitTorrent control (drive a node with no UI) ---
      if (req.method == 'GET' && path == '/api/media/torrents') {
        return _json(res, {'torrents': TorrentService.instance.status()});
      }
      if (req.method == 'GET' && path == '/api/media/has') {
        final archive = _mediaArchive();
        final raw = req.uri.queryParameters['sha256'] ?? '';
        // archive.has() accepts a token, hex, or b64u and normalises internally.
        final has = archive != null && raw.isNotEmpty && archive.has(raw);
        return _json(res, {'sha256': raw, 'has': has});
      }
      if (req.method == 'POST' && path == '/api/media/fetch') {
        final data = await _body(req);
        final ihRaw = (data['ih'] ?? data['infohash'] ?? '').toString().toLowerCase();
        final sha256 = (data['sha256'] ?? '').toString();
        final ext = (data['ext'] ?? 'bin').toString();
        if (_mediaArchive() == null) {
          return _json(res, {'ok': false, 'error': 'storage not ready'},
              status: HttpStatus.serviceUnavailable);
        }
        if (sha256.isEmpty) {
          return _json(res, {'ok': false, 'error': 'sha256 required'},
              status: HttpStatus.badRequest);
        }
        final ih = RegExp(r'^[0-9a-f]{40}$').hasMatch(ihRaw) ? ihRaw : null;
        // Full tiered resolution: cache → LAN Blossom → public Blossom →
        // BitTorrent. Fire-and-forget (the swarm tier can run for minutes);
        // poll /api/media/has and /api/media/torrents to observe completion.
        resolveSharedMedia(sha256, ext, ih: ih).then((ok) => LogService.instance
            .add('RemoteApi: media resolve $sha256 -> ${ok ? 'ok' : 'failed'}'));
        return _json(res, {'ok': true, 'started': true, 'sha256': sha256, 'ih': ih});
      }
      if (req.method == 'POST' && path == '/api/media/put') {
        // Insert bytes into the local media archive (test/tooling aid):
        // {"data":"<base64>","ext":"jpg","name":"photo"} → {"token": ...}
        final data = await _body(req);
        final archive = _mediaArchive();
        if (archive == null) {
          return _json(res, {'ok': false, 'error': 'storage not ready'},
              status: HttpStatus.serviceUnavailable);
        }
        try {
          final bytes = base64Decode((data['data'] ?? '').toString());
          final token = archive.putBytes(
              bytes, (data['ext'] ?? 'bin').toString(),
              name: data['name']?.toString());
          return _json(res, {'ok': true, 'token': token, 'size': bytes.length});
        } catch (e) {
          return _json(res, {'ok': false, 'error': '$e'},
              status: HttpStatus.badRequest);
        }
      }
      if (req.method == 'POST' && path == '/api/media/publish') {
        final data = await _body(req);
        final token = (data['token'] ?? '').toString();
        final archive = _mediaArchive();
        if (archive == null) {
          return _json(res, {'ok': false, 'error': 'storage not ready'},
              status: HttpStatus.serviceUnavailable);
        }
        final ref = MediaRef.parse(token);
        if (ref == null) {
          return _json(res, {'ok': false, 'error': 'bad token'},
              status: HttpStatus.badRequest);
        }
        final bytes = archive.get(ref.sha256);
        if (bytes == null) {
          return _json(res, {'ok': false, 'error': 'not in archive'},
              status: HttpStatus.notFound);
        }
        final profile = ProfileService.instance.activeProfile;
        if (profile == null) {
          return _json(res, {'ok': false, 'error': 'no profile'},
              status: HttpStatus.serviceUnavailable);
        }
        String privHex;
        try {
          privHex = NostrCrypto.decodeNsec(profile.nsec);
        } catch (_) {
          return _json(res, {'ok': false, 'error': 'bad key'},
              status: HttpStatus.internalServerError);
        }
        final n =
            await BlossomServer.publishToPublic(bytes, privHex, ext: ref.ext);
        return _json(res, {'ok': n > 0, 'token': token, 'servers': n});
      }
      if (req.method == 'POST' && path == '/api/media/seed') {
        final data = await _body(req);
        final token = (data['token'] ?? '').toString();
        if (_mediaArchive() == null) {
          return _json(res, {'ok': false, 'error': 'storage not ready'},
              status: HttpStatus.serviceUnavailable);
        }
        final ih = await TorrentService.instance.seed(token);
        return _json(res, {'ok': ih != null, 'token': token, 'ih': ih},
            status: ih != null ? HttpStatus.ok : HttpStatus.badRequest);
      }
      // --- headless I2P control (pure-Dart node; drive desktop<->phone) ---
      if (req.method == 'GET' && path == '/api/i2p/status') {
        final s = I2pService.instance;
        return _json(res, {'up': s.isUp, 'starting': s.isStarting, 'b32': s.b32});
      }
      if (req.method == 'POST' && path == '/api/i2p/start') {
        // Reseed + tunnel build can take a while; start in the background and
        // poll GET /api/i2p/status for {up:true, b32}.
        I2pService.instance.ensureStarted();
        return _json(res, {'started': true});
      }
      if (req.method == 'POST' && path == '/api/i2p/put') {
        final data = await _body(req);
        final archive = _mediaArchive();
        if (archive == null) {
          return _json(res, {'ok': false, 'error': 'storage not ready'},
              status: HttpStatus.serviceUnavailable);
        }
        final bytes = base64.decode((data['data'] ?? '').toString());
        final ext = (data['ext'] ?? 'bin').toString();
        final token = archive.putBytes(bytes, ext);
        final ref = MediaRef.parse(token);
        return _json(res, {
          'ok': true,
          'token': token,
          'sha256': ref?.sha256,
          'sha256hex': ref?.sha256Hex,
          'len': bytes.length,
        });
      }
      if (req.method == 'POST' && path == '/api/i2p/fetch') {
        final data = await _body(req);
        final b32 = (data['b32'] ?? '').toString();
        final ext = (data['ext'] ?? 'bin').toString();
        final sha = _shaBytes((data['sha256'] ?? '').toString());
        if (!I2pService.instance.isUp) {
          return _json(res, {'ok': false, 'error': 'i2p not up'},
              status: HttpStatus.serviceUnavailable);
        }
        if (b32.isEmpty || sha == null) {
          return _json(res, {'ok': false, 'error': 'b32 and sha256 required'},
              status: HttpStatus.badRequest);
        }
        final ok = await I2pService.instance.fetchByB32(b32, sha, ext);
        return _json(res, {'ok': ok});
      }
      if (req.method == 'POST' && path == '/api/i2p/peer') {
        // Register a peer's callsign -> b32 (roster for content discovery).
        final data = await _body(req);
        final cs = (data['callsign'] ?? '').toString();
        final b32 = (data['b32'] ?? '').toString();
        if (cs.isEmpty || b32.isEmpty) {
          return _json(res, {'ok': false, 'error': 'callsign and b32 required'},
              status: HttpStatus.badRequest);
        }
        I2pService.instance.registerB32(cs, b32);
        return _json(res, {'ok': true});
      }
      if (req.method == 'POST' && path == '/api/i2p/announce') {
        final sha = _shaBytes((await _body(req))['sha256']?.toString() ?? '');
        if (!I2pService.instance.isUp || sha == null) {
          return _json(res, {'ok': false, 'error': 'i2p not up / bad sha256'},
              status: HttpStatus.serviceUnavailable);
        }
        await I2pService.instance.announce(sha);
        return _json(res, {'ok': true});
      }
      if (req.method == 'POST' && path == '/api/i2p/discover') {
        // Find any provider of this sha256 across the network and archive it.
        final data = await _body(req);
        final sha = _shaBytes((data['sha256'] ?? '').toString());
        final ext = (data['ext'] ?? 'bin').toString();
        if (!I2pService.instance.isUp || sha == null) {
          return _json(res, {'ok': false, 'error': 'i2p not up / bad sha256'},
              status: HttpStatus.serviceUnavailable);
        }
        final ok = await I2pService.instance.discover(sha, ext);
        return _json(res, {'ok': ok});
      }

      // ── WiFi Direct bulk data plane (validation control) ──
      if (req.method == 'GET' && path == '/api/wfd/status') {
        final wfd = WifiDirectService.instance;
        return _json(res, {
          'supported': await wfd.supported(),
          'group': await wfd.groupInfo(),
          'coordinator': {
            'groupUp': WifiDirectCoordinator.instance.groupUp,
            'powered': WifiDirectCoordinator.instance.powered,
            'enabled': WifiDirectCoordinator.instance.enabled,
          },
          'wfdIfaces': RnsService.instance.wfdIfaceLabels(),
        });
      }
      if (req.method == 'POST' && path == '/api/wfd/group') {
        // Ensure/reuse THE group on this device; returns live credentials and
        // serves RNS on the group interface (rank-4 wfd data plane).
        final creds = await WifiDirectService.instance.ensureGroup();
        if (creds == null) return _json(res, {'ok': false});
        final rns = await RnsService.instance.enableWfdServer(kWfdRnsPort);
        return _json(res, {'ok': true, 'rns': rns, ...creds.toJson()});
      }
      if (req.method == 'POST' && path == '/api/wfd/join') {
        // {"ssid": "...", "psk": "..."} → silent credential join; waits for
        // link-up and dials the GO's RNS server over the P2P pipe.
        final data = await _body(req);
        final ssid = (data['ssid'] ?? '').toString();
        final psk = (data['psk'] ?? '').toString();
        final wfd = WifiDirectService.instance;
        final started = await wfd.connectToGroup(ssid, psk);
        if (!started) return _json(res, {'ok': false, 'error': 'connect refused'});
        final goIp = await wfd.awaitConnected();
        if (goIp == null) return _json(res, {'ok': false, 'error': 'link timeout'});
        final rns = await RnsService.instance.attachWfdClient(goIp, kWfdRnsPort);
        return _json(res, {'ok': true, 'goIp': goIp, 'rns': rns});
      }
      if (req.method == 'POST' && path == '/api/wfd/teardown') {
        await RnsService.instance.detachWfd();
        return _json(res, {'ok': await WifiDirectService.instance.removeGroup()});
      }
      if (req.method == 'POST' && path == '/api/wfd/connect') {
        // {"dest": destHex} → drive the FULL zero-touch coordinator path
        // (BLE negotiation → group → RNS attach) to that peer.
        final data = await _body(req);
        final dest = (data['dest'] ?? '').toString();
        if (dest.isEmpty) {
          return _json(res, {'ok': false, 'error': 'dest required'},
              status: HttpStatus.badRequest);
        }
        final ok = await WifiDirectCoordinator.instance
            .ensureFastPath(dest, force: data['force'] == true);
        return _json(res, {
          'ok': ok,
          'via': RnsService.instance.pathViaFor(dest),
          'groupUp': WifiDirectCoordinator.instance.groupUp,
        });
      }
      if (req.method == 'POST' && path == '/api/wfd/fetch') {
        // {"sha256": hex, "dest": destHex} → fetch the file from that peer and
        // report WHICH interface the path used (must be wfd…, not lan) + speed.
        final data = await _body(req);
        final sha = (data['sha256'] ?? '').toString();
        final dest = (data['dest'] ?? '').toString();
        final shaBytes = _hexBytes(sha);
        if (shaBytes == null || dest.isEmpty) {
          return _json(res, {'ok': false, 'error': 'sha256+dest required'},
              status: HttpStatus.badRequest);
        }
        final viaBefore = RnsService.instance.pathViaFor(dest);
        final t0 = DateTime.now();
        final bytes = await RnsService.instance
            .fetchFileFrom(shaBytes, dest, timeout: const Duration(seconds: 60));
        final ms = DateTime.now().difference(t0).inMilliseconds;
        // Store the received bytes so a subsequent /api/media/has confirms it.
        if (bytes != null) {
          _mediaArchive()?.putBytes(bytes, 'bin');
        }
        return _json(res, {
          'ok': bytes != null,
          'bytes': bytes?.length ?? 0,
          'ms': ms,
          'kBps': bytes != null && ms > 0
              ? ((bytes.length / 1024) / (ms / 1000)).round()
              : 0,
          'viaBefore': viaBefore,
          'via': RnsService.instance.pathViaFor(dest),
          'wfdIfaces': RnsService.instance.wfdIfaceLabels(),
        });
      }

      // ── Reticulum (RNS) device-to-device validation ──
      if (req.method == 'GET' && path == '/api/rns/status') {
        return _json(res, RnsService.instance.status());
      }
      if (req.method == 'POST' && path == '/api/rns/start') {
        // {"mode":"tcpserver"|"tcpclient"|"ble","host":"127.0.0.1","port":4242}
        final data = await _body(req);
        final mode = (data['mode'] ?? 'tcpclient').toString();
        final host = (data['host'] ?? '127.0.0.1').toString();
        final port = int.tryParse('${data['port'] ?? 4242}') ?? 4242;
        // Announce our callsign so peers/repeaters can show a human name (the
        // announce app_data is plaintext; this is a public presence beacon).
        final cs = (ProfileService.instance.activeProfile?.callsign ?? '').trim();
        final name = cs.isNotEmpty ? cs : 'xprs';
        // Serve content we already hold (received media, imports) over RNS.
        final arch = _mediaArchive();
        if (arch != null) {
          RnsService.instance.fileServeSource = MediaFileSource(arch);
        }
        // Persist the social relay/index DB + folder key-store under the shared
        // wapp-data root.
        final prefs = PreferencesService.instanceSync;
        if (prefs != null) {
          RnsService.instance.relayStorePath =
              wappsDataStorage(prefs).getAbsolutePath('social.sqlite3');
          RnsService.instance.callPeersPath =
              wappsDataStorage(prefs).getAbsolutePath('call_peers.json');
          RnsService.instance.relayCursorsPath =
              wappsDataStorage(prefs).getAbsolutePath('relay_cursors.json');
          RnsService.instance.partialStoreDir =
              wappsDataStorage(prefs).getAbsolutePath('partials');
          RnsService.instance.folderStorePath =
              wappsDataStorage(prefs).getAbsolutePath('folders.json');
          RnsService.instance.diskFoldersPath =
              wappsDataStorage(prefs).getAbsolutePath('disk_folders.json');
          RnsService.instance.subscriptionsPath =
              wappsDataStorage(prefs).getAbsolutePath('folder_subscriptions.json');
          RnsService.instance.serveStatsPath =
              wappsDataStorage(prefs).getAbsolutePath('serve_stats.sqlite3');
          RnsService.instance.popularityPath = wappsDataStorage(prefs)
              .getAbsolutePath('folder_popularity.sqlite3');
          RnsService.instance.identityPath =
              wappsDataStorage(prefs).getAbsolutePath('rns_identity.key');
        }
        final ok = await RnsService.instance
            .start(mode: mode, host: host, port: port, announceName: name);
        return _json(res, {'started': ok, ...RnsService.instance.status()});
      }
      // Attach one more hub uplink to a running node -- what lets a
      // tcpserver node (the door for local boards) also stand on the
      // public mesh. Persists into the bootstrap list.
      if (req.method == 'POST' && path == '/api/rns/uplink') {
        final data = await _body(req);
        final ep = (data['endpoint'] ?? '').toString().trim();
        if (ep.isEmpty) {
          return _json(res, {'ok': false, 'error': 'need endpoint host[:port]'},
              status: HttpStatus.badRequest);
        }
        final ok = await RnsService.instance.addBootstrap(ep);
        return _json(res, {'ok': ok, 'endpoint': ep});
      }
      if (req.method == 'POST' && path == '/api/rns/announce') {
        // {"text":"hello"} — one-to-many announce of our chat destination.
        final data = await _body(req);
        final text = (data['text'] ?? '').toString();
        if (!RnsService.instance.isUp) {
          return _json(res, {'ok': false, 'error': 'rns not up'},
              status: HttpStatus.serviceUnavailable);
        }
        await RnsService.instance.announce(text);
        return _json(res, {'ok': true});
      }
      if (req.method == 'GET' && path == '/api/rns/inbox') {
        return _json(res, {'inbox': RnsService.instance.inbox});
      }
      if (req.method == 'POST' && path == '/api/rns/requestpath') {
        // {"dest":"<32hex>"} — pull a path to a destination whose announce
        // never passively flooded to us. Poll /api/rns/haspath to see it land.
        final dest = '${(await _body(req))['dest'] ?? ''}'.trim();
        final ok = RnsService.instance.requestPath(dest);
        return _json(res, {'ok': ok, 'dest': dest,
            'has': RnsService.instance.hasPathTo(dest)});
      }
      if (req.method == 'GET' && path == '/api/rns/haspath') {
        final dest = (req.uri.queryParameters['dest'] ?? '').trim();
        return _json(res,
            {'dest': dest, 'has': RnsService.instance.hasPathTo(dest)});
      }
      if (req.method == 'GET' && path == '/api/rns/route') {
        // ?dest=<32hex> — routing diagnostics (next hop, via iface, hops, age).
        final dest = (req.uri.queryParameters['dest'] ?? '').trim();
        return _json(res, RnsService.instance.routeInfo(dest));
      }
      if (req.method == 'POST' && path == '/api/rns/lxmf/send') {
        // {"dest":"<lxmf delivery dest 32hex>","title":"..","content":".."}
        // Reliable addressed delivery (auto path-request). Returns delivery ok.
        final data = await _body(req);
        final ok = await RnsService.instance.sendLxmf(
          destHex: '${data['dest'] ?? ''}'.trim(),
          title: '${data['title'] ?? ''}',
          content: '${data['content'] ?? ''}',
        );
        return _json(res, {'ok': ok});
      }
      if (req.method == 'POST' && path == '/api/rns/lxmf/pull') {
        // {"dest":"<peer propagation dest 32hex>"} — pull store-and-forwarded
        // messages a peer holds for us (we initiate the link). Returns count.
        final dest = '${(await _body(req))['dest'] ?? ''}'.trim();
        final n = await RnsService.instance.pullLxmf(dest);
        return _json(res, {'ok': true, 'delivered': n});
      }
      if (req.method == 'POST' && path == '/api/rns/get') {
        // {"sha256":"<hex|b64u>","ext":"png"} — DISCOVER providers via the DHT,
        // fetch the bytes from the best one, cache them, and auto-seed (publish
        // our own provider record). No peer needed; the DHT is the index.
        final data = await _body(req);
        final shaB = _shaBytes('${data['sha256'] ?? ''}');
        final ext = '${data['ext'] ?? 'bin'}';
        if (shaB == null) {
          return _json(res, {'ok': false, 'error': 'sha256 required'},
              status: HttpStatus.badRequest);
        }
        // Optional "from" callsign → fetch DIRECTLY from that known sender first
        // (reliable cross-network), falling back to DHT discovery.
        final from = '${data['from'] ?? ''}'.trim();
        Uint8List? bytes;
        if (from.isNotEmpty) {
          bytes = await RnsService.instance.fetchFileFromCallsign(shaB, from);
        }
        bytes ??= await RnsService.instance.dhtResolveFetch(shaB);
        if (bytes == null) {
          return _json(res, {'ok': false, 'error': 'not found'});
        }
        String? token;
        final arch = _mediaArchive();
        if (arch != null) token = arch.putBytes(bytes, ext);
        final holders = await RnsService.instance.dhtPublish(shaB); // auto-seed
        return _json(res,
            {'ok': true, 'len': bytes.length, 'token': token, 'seeded': holders});
      }
      if (req.method == 'POST' && path == '/api/rns/seed') {
        // {"sha256":"<hex|b64u>"} — publish a provider record for content we hold,
        // so peers can discover us as a source.
        final data = await _body(req);
        final shaB = _shaBytes('${data['sha256'] ?? ''}');
        if (shaB == null) {
          return _json(res, {'ok': false, 'error': 'sha256 required'},
              status: HttpStatus.badRequest);
        }
        final holders = await RnsService.instance.dhtPublish(shaB);
        return _json(res, {'ok': true, 'seeded': holders});
      }
      if (req.method == 'POST' && path == '/api/rns/fetchfile') {
        // {"sha256":"<hex|b64u>","peer":"<peer dest hex>","ext":"png"} — fetch a
        // file by content hash from a known peer over a Reticulum link; on success
        // cache it in MediaArchive (so we can then serve it too).
        final data = await _body(req);
        final shaB = _shaBytes('${data['sha256'] ?? ''}');
        final peer = '${data['peer'] ?? ''}'.trim();
        final ext = '${data['ext'] ?? 'bin'}';
        if (shaB == null || peer.isEmpty) {
          return _json(res, {'ok': false, 'error': 'sha256 + peer required'},
              status: HttpStatus.badRequest);
        }
        final bytes = await RnsService.instance.fetchFileFrom(shaB, peer);
        if (bytes == null) {
          return _json(res, {'ok': false, 'error': 'fetch failed'});
        }
        String? token;
        final arch = _mediaArchive();
        if (arch != null) token = arch.putBytes(bytes, ext);
        return _json(res, {'ok': true, 'len': bytes.length, 'token': token});
      }
      if (req.method == 'POST' && path == '/api/rns/relay/publish') {
        // {"event": {NIP-01 signed event json}} — store locally + fan out to an
        // indexer. The event must already be Schnorr-signed by the caller.
        final data = await _body(req);
        final ev = data['event'];
        if (ev is! Map) {
          return _json(res, {'ok': false, 'error': 'event object required'},
              status: HttpStatus.badRequest);
        }
        final ok = await RnsService.instance
            .relayPublish(Map<String, dynamic>.from(ev));
        return _json(res, {'ok': ok});
      }
      if (req.method == 'POST' && path == '/api/rns/relay/search') {
        // {"q":"text","kinds":[1],"limit":50,"topic":"reticulum"}
        final data = await _body(req);
        final q = '${data['q'] ?? ''}';
        final kinds = (data['kinds'] as List?)?.map((e) => e as int).toList();
        final limit = int.tryParse('${data['limit'] ?? 50}') ?? 50;
        final topic = data['topic']?.toString();
        final events = await RnsService.instance
            .relaySearch(q, kinds: kinds, limit: limit, topic: topic);
        return _json(res, {'ok': true, 'count': events.length, 'events': events});
      }
      if (req.method == 'POST' && path == '/api/rns/relay/query') {
        // {"filter":{NIP-01 filter}, "topic":"reticulum"}
        final data = await _body(req);
        final filter = data['filter'];
        if (filter is! Map) {
          return _json(res, {'ok': false, 'error': 'filter object required'},
              status: HttpStatus.badRequest);
        }
        final events = await RnsService.instance.relayQuery(
            Map<String, dynamic>.from(filter),
            topic: data['topic']?.toString());
        return _json(res, {'ok': true, 'count': events.length, 'events': events});
      }
      if (req.method == 'POST' && path == '/api/rns/relay/topic') {
        // {"topic":"reticulum"} — add a topic to our indexer interest set.
        final data = await _body(req);
        final topic = '${data['topic'] ?? ''}'.trim();
        if (topic.isEmpty) {
          return _json(res, {'ok': false, 'error': 'topic required'},
              status: HttpStatus.badRequest);
        }
        RnsService.instance.addRelayTopic(topic);
        return _json(res, {'ok': true, 'indexers': RnsService.instance.relayIndexerCount});
      }
      if (req.method == 'POST' && path == '/api/rns/folder/create') {
        // {"name":"My folder","desc":"...","type":"private|readonly|collab"}
        // type=collab makes a synced, multi-writer folder (every member and
        // every device of this account can add files).
        final data = await _body(req);
        final name = '${data['name'] ?? ''}'.trim();
        if (name.isEmpty) {
          return _json(res, {'ok': false, 'error': 'name required'},
              status: HttpStatus.badRequest);
        }
        var type = '${data['type'] ?? 'private'}'.trim();
        if (!FolderShareType.all.contains(type)) type = FolderShareType.private;
        final id = RnsService.instance.folderCreate(name,
            desc: '${data['desc'] ?? ''}', shareType: type);
        return _json(res, {'ok': id != null, 'folderId': id, 'type': type});
      }
      if (req.method == 'POST' && path == '/api/rns/folder/edit') {
        // {"folderId":"<hex>","op":{"op":"addFile","x":"<sha256hex>",...}}
        final data = await _body(req);
        final folderId = '${data['folderId'] ?? ''}'.trim();
        final op = data['op'];
        if (folderId.isEmpty || op is! Map) {
          return _json(res, {'ok': false, 'error': 'folderId + op required'},
              status: HttpStatus.badRequest);
        }
        RnsService.instance
            .folderEdit(folderId, Map<String, dynamic>.from(op));
        return _json(res, {'ok': true});
      }
      if (req.method == 'POST' && path == '/api/rns/folder/browse') {
        // {"folderId":"<hex>"} -> the cached folder state (refreshes async).
        final data = await _body(req);
        final folderId = '${data['folderId'] ?? ''}'.trim();
        if (folderId.isEmpty) {
          return _json(res, {'ok': false, 'error': 'folderId required'},
              status: HttpStatus.badRequest);
        }
        return _json(res,
            {'ok': true, 'state': RnsService.instance.folderBrowse(folderId)});
      }
      if (req.method == 'GET' && path == '/api/rns/folder/list') {
        return _json(res, {'folders': RnsService.instance.folderList()});
      }
      if (req.method == 'POST' && path == '/api/rns/folder/adddisk') {
        // {"path":"/abs/dir"} — register an on-disk directory as an owned folder
        // (served from disk, not copied to the archive).
        final data = await _body(req);
        final p = '${data['path'] ?? ''}'.trim();
        if (p.isEmpty) {
          return _json(res, {'ok': false, 'error': 'path required'},
              status: HttpStatus.badRequest);
        }
        final id = await RnsService.instance.folderAddFromDisk(p);
        return _json(res, {'ok': id != null, 'folderId': id});
      }
      if (req.method == 'POST' && path == '/api/rns/folder/rescan') {
        final data = await _body(req);
        final fid = data['folderId']?.toString();
        await RnsService.instance.folderRescan(fid);
        return _json(res, {'ok': true, 'owned': RnsService.instance.ownedDiskFolders()});
      }
      if (req.method == 'POST' && path == '/api/rns/folder/download') {
        // {"folderId":..,"sha":..,"name":..} or {"folderId":..,"all":true}
        final data = await _body(req);
        final fid = '${data['folderId'] ?? ''}'.trim();
        if (fid.isEmpty) {
          return _json(res, {'ok': false, 'error': 'folderId required'},
              status: HttpStatus.badRequest);
        }
        if (data['all'] == true) {
          final n = await RnsService.instance.folderDownloadAll(fid);
          return _json(res, {'ok': true, 'downloaded': n});
        }
        final sha = '${data['sha'] ?? ''}'.trim();
        final name = '${data['name'] ?? sha}';
        if (sha.isEmpty) {
          return _json(res, {'ok': false, 'error': 'sha or all required'},
              status: HttpStatus.badRequest);
        }
        final ok = await RnsService.instance.folderDownloadFile(fid, sha, name);
        return _json(res, {'ok': ok});
      }
      if (req.method == 'POST' && path == '/api/rns/folder/autosync') {
        // {"folderId":..,"on":true}
        final data = await _body(req);
        final fid = '${data['folderId'] ?? ''}'.trim();
        if (fid.isEmpty) {
          return _json(res, {'ok': false, 'error': 'folderId required'},
              status: HttpStatus.badRequest);
        }
        RnsService.instance.setFolderAutoSync(fid, data['on'] == true);
        return _json(res, {'ok': true});
      }
      if (req.method == 'GET' && path == '/api/rns/folder/subscriptions') {
        return _json(res, {'subscriptions': RnsService.instance.folderSubscriptions()});
      }
      if (req.method == 'GET' && path == '/api/rns/folder/owned') {
        return _json(res, {'owned': RnsService.instance.ownedDiskFolders()});
      }
      // ── Torrents (docs/torrents.md) ────────────────────────────────────────
      // The folder's shareable pointer: ntorrent1… (key + provider hints + author).
      if (req.method == 'GET' && path == '/api/rns/folder/link') {
        final fid = '${req.uri.queryParameters['folderId'] ?? ''}'.trim();
        if (fid.isEmpty) {
          return _json(res, {'ok': false, 'error': 'folderId required'},
              status: HttpStatus.badRequest);
        }
        return _json(res, {'ok': true, 'link': RnsService.instance.folderLink(fid)});
      }
      // Who has this folder: the holders + their physical profile, best first.
      // Answers from the cached snapshot and refreshes in the background, so a
      // cold call legitimately returns [] — ask again in a moment.
      if (req.method == 'GET' && path == '/api/rns/folder/swarm') {
        final fid = '${req.uri.queryParameters['folderId'] ?? ''}'.trim();
        if (fid.isEmpty) {
          return _json(res, {'ok': false, 'error': 'folderId required'},
              status: HttpStatus.badRequest);
        }
        return _json(
            res, {'ok': true, 'holders': RnsService.instance.folderSwarm(fid)});
      }
      // The listing's artwork as media tokens (same as the wapp's hal_folder_media)
      // — drives the disk→archive copy and returns what the gallery would render.
      if (req.method == 'GET' && path == '/api/rns/folder/media') {
        final fid = '${req.uri.queryParameters['folderId'] ?? ''}'.trim();
        if (fid.isEmpty) {
          return _json(res, {'ok': false, 'error': 'folderId required'},
              status: HttpStatus.badRequest);
        }
        return _json(res, RnsService.instance.folderMediaTokens(fid));
      }
      // Open one file with the system viewer (gallery / reader / installer).
      // {"folderId":..,"sha":..,"name":..}. A downloaded file is exported out of
      // the content-addressed archive on a worker isolate first; a disk-backed
      // one is opened in place. false = we don't hold it, or nothing here opens
      // that type.
      if (req.method == 'POST' && path == '/api/rns/folder/open') {
        final data = await _body(req);
        final fid = '${data['folderId'] ?? ''}'.trim();
        final sha = '${data['sha'] ?? ''}'.trim();
        if (fid.isEmpty || sha.isEmpty) {
          return _json(res, {'ok': false, 'error': 'folderId and sha required'},
              status: HttpStatus.badRequest);
        }
        final ok = await RnsService.instance
            .folderOpenFile(fid, sha, name: '${data['name'] ?? ''}');
        return _json(res, {'ok': ok});
      }
      // Pin/unpin: keep a full copy and advertise ourselves to the Indexers.
      if (req.method == 'POST' && path == '/api/rns/folder/pin') {
        // {"folderId":..,"on":true}
        final data = await _body(req);
        final fid = '${data['folderId'] ?? ''}'.trim();
        if (fid.isEmpty) {
          return _json(res, {'ok': false, 'error': 'folderId required'},
              status: HttpStatus.badRequest);
        }
        RnsService.instance.folderPin(fid, data['on'] == true);
        return _json(res,
            {'ok': true, 'pinned': RnsService.instance.folderPinned(fid)});
      }
      // ── Updates panel (drives the real UpdateService) ──────────────────────
      if (req.method == 'POST' && path == '/api/update/config') {
        // {"betaFolder":"<npub|hex>","beta":true} — point the beta channel at a
        // folder and enable it (self-hoster / test config).
        final data = await _body(req);
        final u = UpdateService.instance;
        await u.load();
        if (data['betaFolder'] != null) {
          await u.setBetaFolder('${data['betaFolder']}'.trim());
        }
        if (data['stableFolder'] != null) {
          await u.setStableFolder('${data['stableFolder']}'.trim());
        }
        if (data['beta'] != null) await u.setBetaEnabled(data['beta'] == true);
        if (data['betaEnabled'] != null) {
          await u.setBetaEnabled(data['betaEnabled'] == true);
        }
        // Point this device at another feed (a staging one, or a self-hoster's).
        // Until now setFeedBase had no caller at all, so the feed could only be
        // changed by rebuilding.
        if (data['feedBase'] != null) {
          await u.setFeedBase('${data['feedBase']}'.trim());
        }
        return _json(res, {
          'ok': true,
          'betaFolder': u.betaFolder,
          'stableFolder': u.stableFolder,
          'betaEnabled': u.betaEnabled,
          'feedBase': u.feedBase,
          'currentVersion': u.currentVersion,
        });
      }
      if (req.method == 'POST' && path == '/api/update/check') {
        // Browse the channel folders over Reticulum and report the newest
        // release + whether it is newer than what's running (the auto-discovery
        // step the Updates panel runs on open / at startup).
        final u = UpdateService.instance;
        await u.load();
        await u.checkForUpdates();
        final sel = u.selectedRelease;
        return _json(res, {
          'ok': true,
          'currentVersion': u.currentVersion,
          'status': u.status.value.name,
          'betaEnabled': u.betaEnabled,
          'beta': _releaseJson(u.beta.value),
          'stable': _releaseJson(u.stable.value),
          'selected': _releaseJson(sel),
          'updateAvailable': u.isNewer(sel),
          'error': u.error,
        });
      }
      if (req.method == 'POST' && path == '/api/update/download') {
        // Fetch the selected release's artifact over Reticulum, verify sha,
        // write to disk. Returns once downloaded (or on error).
        final u = UpdateService.instance;
        final sel = u.selectedRelease;
        if (sel == null || !u.isNewer(sel)) {
          return _json(res, {'ok': false, 'error': 'no newer release selected'});
        }
        final ok = await u.download(sel);
        return _json(res, {
          'ok': ok,
          'version': sel.version,
          'status': u.status.value.name,
          'downloadedPath': u.downloadedPath,
          'source': u.lastSource,
          'phase': u.phase.value,
          'canInstall': await UpdateNative.canInstall(),
          'error': u.error,
        });
      }
      if (req.method == 'GET' && path == '/api/update/status') {
        // The whole read-only picture, so "does this phone see an update?" is
        // one GET with no side effect. It used to report six fields and omit
        // every one that answers that question -- only POST /api/update/check
        // had them, and that runs a network check to tell you.
        final u = UpdateService.instance;
        final sel = u.selectedRelease;
        return _json(res, {
          'currentVersion': u.currentVersion,
          'buildNumber': kBuildNumber,
          'betaEnabled': u.betaEnabled,
          'autoCheck': u.autoCheck,
          'feedBase': u.feedBase,
          'stableFolder': u.stableFolder,
          'betaFolder': u.betaFolder,
          'supported': u.supported,
          'status': u.status.value.name,
          'progress': u.progress.value,
          'stable': _releaseJson(u.stable.value),
          'beta': _releaseJson(u.beta.value),
          'selected': _releaseJson(sel),
          'updateAvailable': u.isNewer(sel),
          'downloadedPath': u.downloadedPath,
          'source': u.lastSource,
          'phase': u.phase.value,
          'canInstall': await UpdateNative.canInstall(),
          'error': u.error,
        });
      }
      if (req.method == 'POST' && path == '/api/update/install') {
        // The verb that was missing: without it the chain check -> download ->
        // install could not be driven end to end without a human tapping.
        final u = UpdateService.instance;
        final sel = u.selectedRelease;
        if (sel == null) {
          return _json(res, {'ok': false, 'error': 'no release selected'},
              status: HttpStatus.badRequest);
        }
        if (u.downloadedPath == null) {
          return _json(res, {'ok': false, 'error': 'nothing downloaded'},
              status: HttpStatus.conflict);
        }
        final ok = await u.install(sel);
        return _json(res, {
          'ok': ok,
          'version': sel.version,
          'status': u.status.value.name,
          'error': u.error,
        });
      }
      // ── XPRS files (section 25.2): cmd:file, both ends ──────────────
      if (req.method == 'GET' && path == '/api/xprs/files') {
        return _json(res, {
          'server': XprsFileServer.instance.statusJson(),
          'fetch': XprsFileFetch.instance.statusJson(),
          'spool': MeshBulkSpool.instance.statusJson(),
        });
      }
      if (req.method == 'POST' && path == '/api/xprs/hold') {
        // {"path":"/abs/file","sha256":"<hex>","name":"x.bin"} — offer one file
        // to anyone who asks for that digest. The digest is supplied, never
        // computed: hashing to answer "do you hold this" is the cost the whole
        // design avoids.
        final data = await _body(req);
        final fpath = '${data['path'] ?? ''}'.trim();
        final sha = '${data['sha256'] ?? ''}'.trim().toLowerCase();
        if (fpath.isEmpty || sha.length != 64) {
          return _json(res, {'ok': false, 'error': 'path and sha256 required'},
              status: HttpStatus.badRequest);
        }
        final f = File(fpath);
        if (!f.existsSync()) {
          return _json(res, {'ok': false, 'error': 'no such file'},
              status: HttpStatus.notFound);
        }
        final name = '${data['name'] ?? fpath.split('/').last}';
        final dot = name.lastIndexOf('.');
        XprsFileServer.instance.hold(XprsHeldFile(
          path: fpath,
          shaHex: sha,
          size: f.lengthSync(),
          name: name,
          ext: dot > 0 ? name.substring(dot + 1) : '',
        ));
        return _json(res, {
          'ok': true,
          'sha256': sha,
          'size': f.lengthSync(),
          'name': name,
        });
      }
      if (req.method == 'POST' && path == '/api/xprs/file') {
        // {"from":"X3ARK","sha256":"<hex>","ext":"bin"} — cmd:file, then wait
        // for the bytes on the bulk lane. Returns when they land and verify.
        final data = await _body(req);
        final from = '${data['from'] ?? ''}'.trim().toUpperCase();
        final sha = '${data['sha256'] ?? ''}'.trim().toLowerCase();
        if (from.isEmpty || sha.length != 64) {
          return _json(res, {'ok': false, 'error': 'from and sha256 required'},
              status: HttpStatus.badRequest);
        }
        final self = MeshService.instance.tableCallsign;
        if (self.isEmpty) {
          return _json(res, {'ok': false, 'error': 'mesh not up'},
              status: HttpStatus.serviceUnavailable);
        }
        final mins = int.tryParse('${data['timeoutMinutes'] ?? ''}');
        final began = DateTime.now().millisecondsSinceEpoch;
        final got = await XprsFileFetch.instance.fetch(
          archiver: from,
          shaHex: sha,
          selfCallsign: NostrCrypto.bareCallsign(self),
          ext: '${data['ext'] ?? ''}',
          destDir: '${data['destDir'] ?? await UpdateNative.supportDir() ?? ''}',
          timeout: mins == null
              ? XprsFileFetch.defaultTimeout
              : Duration(minutes: mins),
        );
        return _json(res, {
          'ok': got != null,
          'path': got,
          'sha256': sha,
          'from': from,
          'elapsedMs': DateTime.now().millisecondsSinceEpoch - began,
        });
      }
      // What this station holds and seeds for the phones around it.
      // Who holds this content? The question the whole update design turns
      // on -- a phone fetches by sha256 from a super-archiver -- and until now
      // the only way to ask it was to start a download and watch it hang.
      if (req.method == 'GET' && path == '/api/files/providers') {
        final sha = (req.uri.queryParameters['sha'] ?? '').trim().toLowerCase();
        if (sha.length != 64) {
          return _json(res, {'ok': false, 'error': 'need sha=<64 hex>'},
              status: HttpStatus.badRequest);
        }
        final n = await RnsService.instance
            .contentProviderCount(sha, timeout: const Duration(seconds: 20));
        return _json(res, {
          'ok': true,
          'sha': sha,
          'mirror': UpdateMirrorService.instance.pathForSha(sha),
          'providers': n,
        });
      }
      if (req.method == 'GET' && path == '/api/update/mirror') {
        return _json(res, UpdateMirrorService.instance.statusJson());
      }
      if (req.method == 'POST' && path == '/api/update/mirror/config') {
        // {"enabled":true} — be a mirror, or stop being one.
        final data = await _body(req);
        final prefs = PreferencesService.instanceSync;
        final m = UpdateMirrorService.instance;
        if (data.containsKey('enabled')) {
          final on = data['enabled'] == true;
          prefs?.updateMirrorEnabled = on;
          if (on && !m.isRunning) {
            await m.start();
          } else if (!on && m.isRunning) {
            await m.stop();
          }
        }
        return _json(res, m.statusJson());
      }
      // Air one XPRS packet on BLE, for validating the radio path end to end
      // from a laptop. {"type":"info","m":"..."} → t:info f:<self> ts:<now>
      // m:<text>, signed, on subtype 0x58. Nothing in the app calls this; it
      // exists so a two-device test can be driven over adb.
      if (req.method == 'POST' && path == '/api/xprs/send') {
        final data = await _body(req);
        final type = (data['type'] ?? 'info').toString();
        final text = (data['m'] ?? '').toString();
        final dest = (data['d'] ?? '').toString().trim().toUpperCase();
        final self = MeshService.instance.tableCallsign.trim();
        if (self.isEmpty) {
          return _json(res, {'ok': false, 'error': 'no callsign yet'},
              status: HttpStatus.serviceUnavailable);
        }
        final now = DateTime.now().toUtc();
        String two(int n) => n.toString().padLeft(2, '0');
        final ts = '${now.year}-${two(now.month)}-${two(now.day)}_'
            '${two(now.hour)}:${two(now.minute)}:${two(now.second)}';

        // A DIRECT message is private by default (docs/XPRS.md section 9.4:
        // encryption is "permitted, and is the default for direct messages"),
        // and `private:false` sends it in the clear instead. The choice is per
        // message because the wire form is per packet (9.2) -- there is no mode
        // to set and nothing to negotiate, so the two forms may alternate
        // freely within one conversation.
        //
        // A broadcast has no recipient to seal to, so it is always plain.
        final wantPrivate = dest.isEmpty
            ? false
            : (data['private'] == null
                ? type == 'message'
                : data['private'] == true);
        // 13.2.2: the relays the sender asks for, in order. Optional; absent
        // means the ordinary rules of 13.1/13.2 decide who repeats it.
        final relay = (data['relay'] ?? '')
            .toString()
            .split(',')
            .map((c) => c.trim().toUpperCase())
            .where((c) => c.isNotEmpty)
            .toList();
        if (relay.isNotEmpty) {
          // A relay: naming more stations than the budget allows names hops
          // that can never fire. Refused here rather than discovered on the
          // air, which is 13.2.2's own advice.
          if (relay.length > xprsRelayLimit(type)) {
            return _json(res, {
              'ok': false,
              'error': 'relay names ${relay.length} hops; '
                  '13.1 allows ${xprsRelayLimit(type)} for t:$type'
            }, status: HttpStatus.badRequest);
          }
          if (relay.contains(self.toUpperCase())) {
            return _json(res,
                {'ok': false, 'error': 'a sender is not one of its own relays'},
                status: HttpStatus.badRequest);
          }
          if (relay.toSet().length != relay.length) {
            return _json(res,
                {'ok': false, 'error': 'a repeated hop can never fire (13.2)'},
                status: HttpStatus.badRequest);
          }
        }
        final relayField = relay.isEmpty ? '' : ' relay:${relay.join(',')}';
        // Every hop appends to `via:`, and the sender never sees the packet
        // that arrives. Leave room for it or the last hop silently refuses to
        // relay a packet that no longer fits (13.2.2's byte note).
        final viaRoom = relay.fold<int>(0, (a, c) => a + c.length + 1) +
            (relay.isEmpty ? 0 : 4);

        if (wantPrivate) {
          final head =
              XprsPacket.parse('t:$type f:$self d:$dest ts:$ts$relayField');
          if (head == null) {
            return _json(res, {'ok': false, 'error': 'malformed'},
                status: HttpStatus.badRequest);
          }
          final built = xprsBuildDirect(
            head: head,
            text: text,
            private: true,
            // The key the recipient published in their `t:identity` (9.3),
            // learned from the air and re-announced every 30 minutes (18.1).
            recipientKeyHex: RnsService.instance.pubkeyForCallsign(dest) ?? '',
          );
          if (!built.ok) {
            if (built.refusal == XprsSealRefusal.noRecipientKey) {
              // Section 18.1: ask, rather than wait for the next announcement.
              unawaited(XprsPublisher.instance.askIdentity(dest));
            }
            // Never silently downgraded: the caller asked for a sealed body and
            // gets told why it could not have one (section 36.8 -- plaintext is
            // disclosure, and the two forms are released under different rules).
            return _json(res, {
              'ok': false,
              'private': true,
              'error': 'cannot seal: ${built.refusal!.name}',
            }, status: HttpStatus.conflict);
          }
          final reports = <Map<String, String>>[];
          for (final part in built.packets) {
            reports.add(await XprsPublisher.instance.publishWire(part.encode()));
            final signed = XprsPublisher.instance.lastWire ?? part.encode();
            MeshCustodyDelegate.onAirFrame(
                Uint8List.fromList(utf8.encode(signed)),
                outbound: true);
          }
          return _json(res, {
            'ok': reports.any((r) => r.values.any((v) => v == 'sent')),
            'private': true,
            'form': 'x',
            'parts': built.packets.length,
            'bytes': built.packets.fold<int>(0, (n, q) => n + q.byteLength),
            'bearers': reports.first,
            'wire': built.packets.first.encode(),
          });
        }

        var p = XprsPacket.parse('t:$type f:$self'
            '${dest.isEmpty ? '' : ' d:$dest'} ts:$ts$relayField m:$text');
        if (p == null || !p.fits) {
          return _json(res, {'ok': false, 'error': 'malformed or too long'},
              status: HttpStatus.badRequest);
        }
        if (p.byteLength + viaRoom > XprsPacket.maxBytes) {
          return _json(res, {
            'ok': false,
            'error': 'too long once every named hop has appended to via:: '
                '${p.byteLength} + $viaRoom > ${XprsPacket.maxBytes}'
          }, status: HttpStatus.badRequest);
        }
        // Through the publisher: every bearer this station has, not a radio
        // this endpoint happens to name (36.0). The publisher also signs and
        // files the wire in our own spool (36.5).
        final report = await XprsPublisher.instance.publishWire(p.encode());
        // Mail is not fire-and-forget: park our own copy for custody
        // (36.7) and let the forwarder move it toward where the recipient
        // actually is (36.8.1) -- the airing above was an attempt, the
        // receipt is what ends the obligation.
        if (dest.isNotEmpty) {
          final signed = XprsPublisher.instance.lastWire ?? p.encode();
          MeshCustodyDelegate.onAirFrame(
              Uint8List.fromList(utf8.encode(signed)),
              outbound: true);
          unawaited(XprsForwarder.instance.maybeForward(
              NostrCrypto.bareCallsign(dest), signed,
              selfBase: NostrCrypto.bareCallsign(self)));
        }
        return _json(res, {
          'ok': report.values.any((v) => v == 'sent'),
          'private': false,
          'form': 'm',
          'bytes': p.byteLength,
          'bearers': report,
          'wire': p.encode(),
        });
      }
      // What this station is carrying for OTHER people (36.7, 13.3).
      //
      // Exposed because custody is invisible when it does not happen: nothing
      // errors and nothing is refused, so "am I a carrier?" had no answer from
      // outside the app — which is exactly how the funnel came to carry mail
      // off the internet lane and nothing off any radio.
      // GET /api/xprs/graph   the local topology, as edges and as a path
      //
      // Every station already broadcasts its own one-hop neighbours in a
      // signed `t:observation` (`link:` + `hears:`, 10.6.1/10.6.3). Composed,
      // those are a graph -- and until this endpoint there was no way to look
      // at it, so "the mesh cannot see its own Bluetooth half" was a thing
      // that could be true for weeks without anybody noticing.
      //
      // ?to=<callsign> also runs the walk and returns a candidate path.
      // ADVISORY, and labelled so: 10.6.3 says `hears:` "informs a choice and
      // never compels one", and nothing here changes what any packet does.
      if (req.method == 'GET' && path == '/api/xprs/graph') {
        final now = DateTime.now().millisecondsSinceEpoch;
        final self = MeshService.instance.tableCallsign.toUpperCase();
        final limit =
            int.tryParse(req.uri.queryParameters['limit'] ?? '') ?? 256;
        final edges = XprsGossip.instance
            .edges(max: limit, selfCallsign: self, nowMs: now);
        final to = (req.uri.queryParameters['to'] ?? '').trim().toUpperCase();
        final maxAgeS =
            int.tryParse(req.uri.queryParameters['maxAgeS'] ?? '') ?? 3600;
        final graph = XprsGraph(edges, nowMs: now, maxAgeMs: maxAgeS * 1000);
        final path0 = to.isEmpty ? null : graph.pathTo(to, from: self);
        // Only the edges the walk is actually allowed to use are listed, or
        // the listing and the path disagree about the same graph and the
        // reader believes the wrong one.
        final fresh = [
          for (final e in edges)
            if (now - e.tsMs <= maxAgeS * 1000 && now - e.tsMs >= 0) e
        ];
        return _json(res, {
          'ok': true,
          'self': self,
          'edges': [for (final e in fresh) e.json(now)],
          'edgesHeld': edges.length,
          'stations': graph.stations.toList()..sort(),
          'bearers': graph.bearers.toList()..sort(),
          'maxAgeS': maxAgeS,
          if (to.isNotEmpty) 'path': path0?.json() ?? {'to': to, 'found': false},
          'advisory': true,
        });
      }

      if (req.method == 'GET' && path == '/api/xprs/held') {
        final limit =
            int.tryParse(req.uri.queryParameters['limit'] ?? '') ?? 50;
        final rows = MeshService.instance.held(limit: limit);
        final self = MeshService.instance.tableCallsign.toUpperCase();
        // CARRIED = somebody else wrote it. That is the number this endpoint
        // exists for: our own outbound has the LXMF ladder behind it, a
        // stranger's mail has this store and nothing else. Keyed on `sender`,
        // not `target` — mail we sent to X1RD89 is not us carrying for anyone.
        final carried = rows
            .where((r) => '${r['sender']}'.toUpperCase() != self)
            .toList();
        final own = rows.length - carried.length;
        int oldest(List<Map<String, dynamic>> l) => l.isEmpty
            ? 0
            : l.map((r) => r['ts'] as int? ?? 0).reduce((a, b) => a < b ? a : b);
        return _json(res, {
          'ok': true,
          'limit': limit,
          'returned': rows.length,
          'carriedRows': carried.length,
          'ownRows': own,
          // Whole-store totals, so a truncated page cannot read as an empty one.
          'pending': MeshStore.instance.ready
              ? MeshStore.instance.pendingCount()
              : null,
          'oldestCarriedTs': oldest(carried),
          'byTarget': {
            for (final t in carried.map((r) => '${r['target']}').toSet())
              t: carried.where((r) => '${r['target']}' == t).length
          },
          // Carried first — heldJson orders them that way deliberately.
          'rows': rows,
        });
      }
      // ── The bearer switchboard: an instrument, not a feature ────────────
      //
      // GET  /api/xprs/bearers            what this station has, and its state
      // POST /api/xprs/bearers {"disable":["lan"]} / {"enable":["lan"]}
      //                        {"only":["ble5"]}  everything else off
      //                        {"reset":true}     all back on
      //
      // Taking a lane away while the station keeps running is the only way to
      // see what it does about it: whether the fallback in the fan-out fires,
      // whether the message is parked for custody instead, whether the retry
      // ladder picks it up. Every one of those is invisible when all four
      // bearers are healthy, which on a bench they always are.
      //
      // In memory only — a forgotten switch cannot outlive the process.
      if (path == '/api/xprs/bearers') {
        final pub = XprsPublisher.instance;
        if (req.method == 'POST') {
          final data = await _body(req);
          final unknown = <String>[];
          void apply(Object? list, bool enabled) {
            for (final e in (list as List?) ?? const []) {
              if (!pub.setBearerEnabled('$e', enabled)) unknown.add('$e');
            }
          }

          if (data['reset'] == true) {
            for (final b in pub.bearers) {
              pub.setBearerEnabled(b.name, true);
            }
          }
          if (data['only'] != null) {
            final keep = ((data['only'] as List?) ?? const [])
                .map((e) => '$e'.toLowerCase())
                .toSet();
            for (final k in keep) {
              if (!pub.bearers.any((b) => b.name == k)) unknown.add(k);
            }
            for (final b in pub.bearers) {
              pub.setBearerEnabled(b.name, keep.contains(b.name));
            }
          }
          apply(data['enable'], true);
          apply(data['disable'], false);
          if (unknown.isNotEmpty) {
            return _json(res, {
              'ok': false,
              'error': 'no such bearer: ${unknown.join(", ")}',
              'bearers': [for (final b in pub.bearers) b.name],
            }, status: HttpStatus.badRequest);
          }
        }
        return _json(res, {
          'ok': true,
          'bearers': {
            for (final b in pub.bearers)
              b.name: {
                'enabled': pub.isBearerEnabled(b.name),
                'active': await b.active,
                'shortRange': b.shortRange,
                'archiveBearer': b.archiveBearer,
              }
          },
          'disabled': pub.disabledBearers.toList(),
        });
      }
      // Configure the super-archivers this station leans on (36.9.4).
      if (req.method == 'POST' && path == '/api/xprs/super') {
        final data = await _body(req);
        final list = (data['supers'] as List?)
                ?.map((e) => e.toString().trim().toUpperCase())
                .where((e) => e.isNotEmpty)
                .toList() ??
            const <String>[];
        final prefs = PreferencesService.instanceSync;
        if (data.containsKey('supers')) prefs?.xprsSuperArchivers = list;
        // {"be": true} — BE one. A super-archiver keeps every callsign's
        // gossip and every public wire, announces `serve:archive,super`, and
        // is what a station with no radio in earshot asks for Global chat
        // (36.9.4). Somebody on the internet has to be one or there is
        // nowhere for the rest to pull from.
        if (data.containsKey('be')) {
          prefs?.xprsSuperArchiver = data['be'] == true;
          // A super-archiver mirrors releases (docs: the phone fetches by sha
          // from a super-archiver, which fetched from xprs.dev). Becoming one
          // at runtime starts the mirror now rather than at the next boot.
          final m = UpdateMirrorService.instance;
          if (m.enabled && !m.isRunning) {
            await m.start();
          } else if (!m.enabled && m.isRunning) {
            await m.stop();
          }
        }
        return _json(res, {
          'ok': true,
          'supers': prefs?.xprsSuperArchivers ?? const <String>[],
          'be': prefs?.xprsSuperArchiver ?? false,
        });
      }
      // Where can a callsign be reached (36.9.4 gossip + 13.12): the
      // internet sender's question, answered in layers.
      // Mint a group (section 26.1): a keypair, the X5 callsign it produces,
      // and the ordinary t:identity that says so. "A group needs no
      // announcement packet of its own, no registry and no creation ceremony.
      // It exists once somebody generates a key and says so."
      if (req.method == 'POST' && path == '/api/xprs/group/create') {
        final data = await _body(req);
        final nick = (data['nick'] ?? '').toString();
        final g = XprsGroupOps.create(nick: nick);
        if (g == null) {
          return _json(res, {'ok': false, 'error': 'could not mint a group'},
              status: HttpStatus.serviceUnavailable);
        }
        return _json(res, {
          'ok': true,
          'group': g.callsign,
          'npub': g.npub,
          'nick': g.nick,
          'announced': true,
        });
      }

      // An act of authority (26.3). One shape for grant and revoke, because
      // one packet type carries every one of them.
      if (req.method == 'POST' &&
          (path == '/api/xprs/group/grant' ||
              path == '/api/xprs/group/revoke')) {
        final data = await _body(req);
        final g = (data['d'] ?? '').toString().trim().toUpperCase();
        final calls = (data['calls'] ?? '')
            .toString()
            .split(',')
            .map((c) => c.trim())
            .where((c) => c.isNotEmpty)
            .toList();
        final r = path.endsWith('grant')
            ? XprsGroupOps.grant(g, calls,
                role: (data['role'] ?? '').toString(),
                until: (data['until'] ?? '').toString())
            : XprsGroupOps.revoke(g, calls,
                until: (data['until'] ?? '').toString(),
                since: (data['since'] ?? '').toString());
        if (!r.ok) {
          return _json(res, {'ok': false, 'error': r.error},
              status: HttpStatus.forbidden);
        }
        return _json(res, {'ok': true, 'wire': r.wire});
      }

      // The member's own half (26.3.1): accepting an offer, or leaving.
      // Signed with the PROFILE key -- this is the person speaking for
      // themselves, not the group speaking about them.
      if (req.method == 'POST' &&
          (path == '/api/xprs/group/accept' ||
              path == '/api/xprs/group/leave')) {
        final data = await _body(req);
        final g = (data['d'] ?? '').toString().trim().toUpperCase();
        final me = MeshService.instance.tableCallsign.trim().toUpperCase();
        final r = path.endsWith('accept')
            ? XprsGroupOps.accept(g, me, (data['r'] ?? '').toString(),
                role: (data['role'] ?? 'member').toString())
            : XprsGroupOps.leave(g, me);
        if (!r.ok) {
          return _json(res, {'ok': false, 'error': r.error},
              status: HttpStatus.badRequest);
        }
        return _json(res, {'ok': true, 'wire': r.wire});
      }

      // One closed group's roster, replayed per section 26.4. The answer to
      // "who belongs, and who may act" without any UI -- which is how stage 1
      // is verified on a phone.
      if (req.method == 'GET' && path == '/api/xprs/group') {
        final d = (req.uri.queryParameters['d'] ?? '').trim().toUpperCase();
        if (d.isEmpty) {
          return _json(res, {'ok': false, 'error': 'need d=<group>'},
              status: HttpStatus.badRequest);
        }
        // `haveKey` is the difference between "closed and empty" and "we could
        // not check": section 26.7 says a client that cannot verify fails open
        // and SAYS SO, so the caller is told which one this is.
        final haveKey =
            XprsGroups.instance.keyResolver?.call(d) != null;
        return _json(res, {
          'ok': true,
          ...XprsGroups.instance.groupJson(d, haveKey: haveKey),
        });
      }

      if (req.method == 'GET' && path == '/api/xprs/whois') {
        final call = (req.uri.queryParameters['call'] ?? '')
            .trim()
            .toUpperCase();
        if (call.isEmpty) {
          return _json(res, {'ok': false, 'error': 'need call='},
              status: HttpStatus.badRequest);
        }
        return _json(res, {
          'ok': true,
          'call': call,
          // The addressed lane, made visible. An empty string here is why a
          // directed packet silently becomes a broadcast announce -- and the
          // public hubs throttle those -- so "can I actually address this
          // station" is the first question when a peer is heard but never
          // answers (36.12.1).
          'lxmfDest': RnsService.instance.lxmfDestForCallsign(call),
          'declared': XprsArchive.instance.holdersFor(call),
          'sightings': [
            for (final s in XprsGossip.instance.whereIs(call))
              {'gateway': s.gateway, 'bearer': s.bearer, 'ts': s.tsMs},
          ],
          'gossip': XprsGossip.instance.statusJson(),
        });
      }
      // The heard-traffic spool, for headless validation: what this station
      // archived, plus its counters. ?since=&until= are XPRS timestamps.
      if (req.method == 'GET' && path == '/api/xprs/history') {
        final q = req.uri.queryParameters;
        // ?to= is a comma list of destinations; an empty element means
        // undirected ("to=,X5KPGF" reads a scope room plus one group).
        final toQ = q['to'];
        final rows = XprsArchive.instance.query(
          sinceMs: xprsParseTs(q['since']),
          untilMs: xprsParseTs(q['until']),
          only: q['only'],
          to: toQ == null ? null : toQ.split(','),
          limit: int.tryParse(q['limit'] ?? '') ?? 50,
        );
        return _json(res, {
          'ok': true,
          'count': rows.length,
          'refusedRns': XprsIngest.refusedRns,
          'archive': XprsArchive.instance.statusJson(),
          'rows': rows,
        });
      }
      // Compose and air a signed cmd:history (docs/XPRS.md §25.2) at another
      // station — /api/xprs/send cannot emit cmd:, and the two-phone replay
      // validation has to be drivable over adb.
      if (req.method == 'POST' && path == '/api/xprs/ask') {
        final data = await _body(req);
        final dest = (data['d'] ?? '').toString().trim().toUpperCase();
        final self = MeshService.instance.tableCallsign.trim();
        if (self.isEmpty || dest.isEmpty) {
          return _json(res, {'ok': false, 'error': 'need d: and a callsign'},
              status: HttpStatus.badRequest);
        }
        final now = DateTime.now().toUtc();
        String two(int n) => n.toString().padLeft(2, '0');
        final ts = '${now.year}-${two(now.month)}-${two(now.day)}_'
            '${two(now.hour)}:${two(now.minute)}:${two(now.second)}';
        var wire = 't:command f:$self d:$dest ts:$ts cmd:history';
        for (final k in ['since', 'until', 'only']) {
          final v = (data[k] ?? '').toString().trim();
          if (v.isNotEmpty) wire += ' $k:$v';
        }
        var p = XprsPacket.parse(wire);
        if (p == null || !p.fits) {
          return _json(res, {'ok': false, 'error': 'malformed or too long'},
              status: HttpStatus.badRequest);
        }
        // The publisher signs (our own wire, no sig: yet) and airs on every
        // bearer -- BLE for the bench, LAN for an ESP32 on this network, and
        // the reticulum hub lane for an archiver across the internet (36.0).
        final report = await XprsPublisher.instance.publishWire(p.encode());
        return _json(res, {
          'ok': report.values.any((v) => v == 'sent'),
          'bearers': report,
          'wire': p.encode(),
        });
      }
      // Declare this station's favorite indexers (XPRS 13.12): persists the
      // hold list and airs the signed t:mailbox on every bearer now.
      if (req.method == 'POST' && path == '/api/xprs/mailbox') {
        final data = await _body(req);
        final hold = (data['hold'] ?? '').toString().trim();
        PreferencesService.instanceSync?.xprsMailboxHold = hold;
        final report = hold.isEmpty
            ? const <String, String>{}
            : await XprsPublisher.instance.publishMailboxDecl(hold);
        return _json(res, {'ok': report.isNotEmpty, 'hold': hold, ...report});
      }
      if (req.method == 'GET' && path == '/api/ble/status') {
        return _json(res, BleService.instance.gattStatus());
      }
      if (req.method == 'POST' && path == '/api/ble/gattsend') {
        // {"size":1024} — send a test blob point-to-point over GATT (auto-pairs).
        final data = await _body(req);
        final size = int.tryParse('${data['size'] ?? 1024}') ?? 1024;
        BleService.instance.gattSendTest(size);
        return _json(res, {'ok': true, 'size': size, ...BleService.instance.gattStatus()});
      }

      // --- headless wapp control (drive a wapp's wasm engine with no UI) ---
      // Runs the wapp as a background service, then injects flat
      // {"command":…} messages and pumps ticks — generic, works for any wapp.
      if (req.method == 'POST' && path == '/api/wapp/start') {
        final name = (await _body(req))['wapp']?.toString() ?? '';
        final dir = await _wappDirFor(name);
        if (dir == null) {
          return _json(res, {'ok': false, 'error': 'unknown wapp'},
              status: HttpStatus.notFound);
        }
        await BackgroundWappManager.instance.start(dir);
        return _json(res,
            {'ok': BackgroundWappManager.instance.isRunning(name), 'wapp': name});
      }
      if (req.method == 'POST' && path == '/api/wapp/stop') {
        final name = (await _body(req))['wapp']?.toString() ?? '';
        await BackgroundWappManager.instance.stop(name);
        return _json(res, {'ok': true, 'wapp': name});
      }
      if (req.method == 'POST' && path == '/api/wapp/cmd') {
        // {"wapp":"circles","msg":{"command":"prompt","prompt_id":"newcircle",
        //  "prompt_input":"My Circle"}} — inject + pump, return the outbox.
        final data = await _body(req);
        final name = data['wapp']?.toString() ?? '';
        final msg = data['msg'];
        final flat = msg is String ? msg : jsonEncode(msg ?? {});
        final out = BackgroundWappManager.instance.injectCommand(name, flat);
        if (out == null) {
          return _json(res, {'ok': false, 'error': 'wapp not running'},
              status: HttpStatus.conflict);
        }
        return _json(res, {'ok': true, 'wapp': name, 'outbox': out});
      }
      if (req.method == 'POST' && path == '/api/wapp/tick') {
        // {"wapp":"circles","n":3} — force N engine ticks (drain RNS etc.).
        final data = await _body(req);
        final name = data['wapp']?.toString() ?? '';
        final n = int.tryParse('${data['n'] ?? 1}') ?? 1;
        final out = BackgroundWappManager.instance.pumpTicks(name, n);
        if (out == null) {
          return _json(res, {'ok': false, 'error': 'wapp not running'},
              status: HttpStatus.conflict);
        }
        return _json(res, {'ok': true, 'wapp': name, 'ticks': n, 'outbox': out});
      }

      return _json(res, {
        'error': 'Not found',
        'endpoints': [
          'GET /api/status',
          'GET /api/log?n=200',
          'GET /api/wapps',
          'POST /api/launch {"wapp":"<id>"}',
          'POST /api/wapp/start {"wapp":"<id>"}',
          'POST /api/wapp/stop {"wapp":"<id>"}',
          'POST /api/wapp/cmd {"wapp":"<id>","msg":{"command":"…",…}}',
          'POST /api/wapp/tick {"wapp":"<id>","n":1}',
          'GET  /api/hero',
          'POST /api/hero/publish {"wapp":"blog","items":[{"id":…,"title":…}]}',
          'GET /api/media/torrents',
          'GET /api/media/has?sha256=<hex|b64u>',
          'POST /api/media/fetch {"sha256":"<hex|b64u>","ext":"png","ih":"<40hex?>"}',
          'POST /api/media/seed {"token":"file:<sha256>.<ext>"}',
          'POST /api/media/publish {"token":"file:<sha256>.<ext>"}',
          'GET /api/i2p/status',
          'POST /api/i2p/start',
          'POST /api/i2p/put {"data":"<base64>","ext":"txt"}',
          'POST /api/i2p/fetch {"b32":"<addr>","sha256":"<hex|b64u>","ext":"txt"}',
          'POST /api/i2p/peer {"callsign":"X1...","b32":"<addr>"}',
          'POST /api/i2p/announce {"sha256":"<hex|b64u>"}',
          'POST /api/i2p/discover {"sha256":"<hex|b64u>","ext":"txt"}',
          'GET /api/rns/status',
          'POST /api/rns/start {"mode":"tcpserver|tcpclient|ble","host":"..","port":4242}',
          'POST /api/rns/announce {"text":"hello"}',
          'GET /api/rns/inbox',
          'GET /api/xprs/group?d=<X5group>',
          'POST /api/xprs/group/create {"nick":"lisboa-net"}',
          'POST /api/xprs/group/grant {"d":"X5..","calls":"X1A,X1B","role":"mod"}',
          'POST /api/xprs/group/revoke {"d":"X5..","calls":"X1A","until":"..."}',
          'POST /api/xprs/group/accept {"d":"X5..","r":"<grant id>"}',
          'POST /api/xprs/group/leave {"d":"X5.."}',
        ],
      }, status: HttpStatus.notFound);
    } catch (e) {
      LogService.instance.add('RemoteApi: handler error: $e');
      try {
        return _json(res, {'error': e.toString()},
            status: HttpStatus.internalServerError);
      } catch (_) {}
    }
  }

  /// Normalise a sha256 given as 64-hex or 43-char base64url to 32 raw bytes.
  Uint8List? _shaBytes(String s) {
    try {
      if (RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(s)) {
        final out = Uint8List(32);
        for (var i = 0; i < 32; i++) {
          out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
        }
        return out;
      }
      if (s.length == 43) {
        final b = base64Url.decode('$s=');
        return b.length == 32 ? b : null;
      }
    } catch (_) {}
    return null;
  }

  /// Decode a hex string into bytes (null on odd length / bad chars).
  Uint8List? _hexBytes(String hex) {
    final s = hex.trim().toLowerCase();
    if (s.isEmpty || s.length.isOdd) return null;
    try {
      final out = Uint8List(s.length ~/ 2);
      for (var i = 0; i < out.length; i++) {
        out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
      }
      return out;
    } catch (_) {
      return null;
    }
  }

  /// Parse a JSON request body into a map (empty on no/invalid body).
  Future<Map<String, dynamic>> _body(HttpRequest req) async {
    final body = await utf8.decoder.bind(req).join();
    if (body.trim().isEmpty) return {};
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) return decoded;
    } catch (_) {}
    return {};
  }

  /// The shared media archive, with TorrentService configured against it and the
  /// per-profile share dir (mirrors shared_media_fetch). Null when storage isn't
  /// ready (e.g. web / before a profile is active).
  MediaArchive? _mediaArchive() {
    final archive = sharedMediaArchive();
    final prefs = PreferencesService.instanceSync;
    if (archive == null || prefs == null) return null;
    TorrentService.instance
        .configure(archive, wappsDataStorage(prefs).getAbsolutePath('share'));
    return archive;
  }

  Future<void> _json(HttpResponse res, Object data, {int status = 200}) async {
    res.statusCode = status;
    res.headers.contentType = ContentType.json;
    res.write(const JsonEncoder.withIndent('  ').convert(data));
    await res.close();
  }

  Map<String, dynamic>? _releaseJson(ReleaseInfo? r) => r == null
      ? null
      : {
          'version': r.version,
          'prerelease': r.isPrerelease,
          'assets': [
            for (final a in r.assets) {'name': a.name, 'url': a.url, 'sha256': a.sha256, 'size': a.size},
          ],
        };

  Future<Map<String, dynamic>> _status() async {
    final p = ProfileService.instance.activeProfile;
    final wapps = await _listWapps();
    // Street-mesh M2 diagnostics: node + custody store + bulk spool state.
    Map<String, dynamic> mesh;
    try {
      final counts = MeshStore.instance.counts();
      mesh = {
        ...jsonDecode(MeshService.instance.statusJson())
            as Map<String, dynamic>,
        'storeReady': MeshStore.instance.ready,
        'pendingMsgs': MeshStore.instance.ready
            ? MeshStore.instance.pendingCount()
            : null,
        'archived': counts.archived,
        'receivedAms': counts.receivedAms,
        'spoolReady': MeshBulkSpool.instance.ready,
        'spoolPending': MeshBulkSpool.instance.pendingCount(),
        'transfers': MeshBulkSpool.instance.transfersJson(),
        'dialable': BleService.instance.meshDialable(),
        // Peers heard recently that CANNOT be dialled, and why. Empty while
        // beacons keep arriving from nobody dialable is the signature of a
        // phone whose legacy discovery scan is not hearing any connectable
        // advert — which is how two phones sat next to each other for hours
        // with `neighbors: 0`.
        'undialable': BleService.instance.meshUndialable(),
        // Who may be handed a 1:1 point to point instead of having it aired,
        // and why. `caps` is the peer's own MSP HELLO declaration; `direct` is
        // the decision that suppresses the broadcast. Exposed because the
        // previous version of this gate read a table that is always empty and
        // there was no way to SEE that from outside the app.
        'custody': BleService.instance.custodyStatus(),
        // Protocol wires refused at the one door into what a person reads.
        // Climbing means machinery is still being handed to the chat by some
        // caller — visible here instead of on somebody's screen.
        'inboxRefusedProtocol': RnsService.instance.inboxRefusedProtocol,
        // Closed groups (section 26): counts only. A status endpoint that
        // serialised every member of every group would be a page fetch to
        // count; /api/xprs/group answers for one group.
        'groups': XprsGroups.instance.statusJson(),
        // Private-message accounting (docs/XPRS.md section 9.2). `sealedAired`
        // and `sealedUnreadable` are the two halves of "did privacy work": one
        // counts what we sent sealed, the other what reached us sealed and
        // would not open. `refusedNoSeal` counts what we declined to send in
        // the clear after being asked for privacy — never silently downgraded.
        // §31.1's budget and the one retry ledger. `deferrals` is the
        // observable that says the budget is alive — a budget nobody can see is
        // indistinguishable from a station that has gone quiet.
        // The LAN bearer's own counters. It had them all along and nothing
        // read them: a phone off its WiFi looked exactly like a quiet LAN.
        'lan': XprsLan.instance.statusJson(),
        'airtime': XprsAirtime.instance.json,
        'retries': XprsRetryLedger.instance.json,
        'receipts': XprsReceiptCounters.json,
        // 13.2.2 and 13.2.1: what this station repeated, what it stood down
        // from, and what it refused. Without these a relay that never fires
        // and a relay that fires and is ignored look identical from outside.
        'digipeat': MeshService.instance.digipeater.json,
        // The other half of §13: what was carried to a medium it had NOT been
        // on, and what went to the operator's archivers. Without it a bridge
        // that never fires and one that fires look identical from outside.
        'bridge': XprsBridge.instance.json,
        'courier': {
          'aired': MeshCourierCounters.aired,
          'ingested': MeshCourierCounters.ingested,
          'refusedNoSeal': MeshCourierCounters.refusedNoSeal,
          'sealedUnreadable': MeshCourierCounters.ingestSealedUnreadable,
          'ingestDropped': MeshCourierCounters.ingestDropped,
        },
        'gatt': BleService.instance.gattStatus(),
        'scheduler': MeshTransferScheduler.instance.statusJson(),
        'neighborPending': {
          for (final n in MeshService.instance.table?.neighbors.values
                  .toList() ??
              <MeshNeighbor>[])
            n.callsign: [n.pendingMsgs, n.pendingBulk]
        },
      };
    } catch (e) {
      mesh = {'error': '$e'};
    }
    return {
      'app': 'xprs',
      'build': kXprsBuildTag,
      // Wedge forensics: the Dart VM service URI (with its auth token) is the
      // only way to pull live isolate stacks/heaps from a stuck app, and it is
      // useless if you can't find it — it scrolls out of the log ring within
      // minutes on a busy node, and out of logcat too. Pin it here so it is
      // always one request away.
      'vmService': LogService.instance.vmServiceUri,
      'mesh': mesh,
      'platform': platform.platformName(),
      'apiPort': _port,
      'profile': p?.nickname,
      'callsign': p?.callsign,
      'npub': p?.npub,
      // Diagnostic: does the active profile's stored npub actually correspond to
      // its nsec? A mismatch means anything peers encrypt to our advertised npub
      // is undecryptable by us (and our signatures won't verify).
      'keyOk': (() {
        try {
          if (p == null || p.nsec.isEmpty || p.npub.isEmpty) return false;
          final privHex = NostrCrypto.decodeNsec(p.nsec);
          final pubHex = NostrCrypto.derivePublicKey(privHex);
          return NostrCrypto.encodeNpub(pubHex) == p.npub;
        } catch (_) {
          return false;
        }
      })(),
      'wappCount': wapps.length,
      'wapps': [for (final w in wapps) w['id']],
    };
  }

  /// Resolve an installed wapp (by folder / id / name) to its package dir, or
  /// null if not installed. Used by the headless wapp-control endpoints.
  Future<String?> _wappDirFor(String key) async {
    if (key.isEmpty) return null;
    for (final w in await _listWapps()) {
      if (w['folder'] == key || w['id'] == key || w['name'] == key) {
        return w['dir'];
      }
    }
    return null;
  }

  Future<List<Map<String, String>>> _listWapps() async {
    final out = <Map<String, String>>[];
    final installed = installedAppsStorage();
    if (!await installed.directoryExists('')) return out;
    for (final e in await installed.listDirectory('')) {
      if (!e.isDirectory) continue;
      try {
        final pkg = wappPackageStorage(installed.getAbsolutePath(e.path));
        final m = await pkg.readJson('manifest.json');
        if (m == null) continue;
        out.add({
          'folder': e.name,
          'id': (m['id'] ?? '').toString(),
          'name': (m['name'] ?? e.name).toString(),
          'title': (m['title'] ?? m['name'] ?? e.name).toString(),
          'kind': (m['kind'] ?? 'app').toString(),
          // Which wapp is ACTUALLY installed, and whether the bundled-wapp
          // upgrade is allowed to replace it. Without these, "the app ships a
          // newer wapp but the device still runs the old one" is undiagnosable
          // from the outside — which is exactly where an hour went.
          'version': (m['version'] ?? '').toString(),
          'user_modified': (m['user_modified'] == true).toString(),
          'dir': pkg.basePath,
        });
      } catch (_) {}
    }
    return out;
  }

  /// Open a wapp by id / folder / name on the root navigator. Returns false
  /// when nothing matches or the navigator isn't available.
  Future<bool> _launch(String key) async {
    if (key.isEmpty) return false;
    final nav = _navigatorKey?.currentState;
    if (nav == null) {
      LogService.instance.add('RemoteApi: launch "$key" — no navigator');
      return false;
    }
    final wapps = await _listWapps();
    Map<String, String>? w;
    for (final x in wapps) {
      if (x['id'] == key || x['folder'] == key || x['name'] == key) {
        w = x;
        break;
      }
    }
    if (w == null) {
      LogService.instance.add('RemoteApi: launch "$key" — not found');
      return false;
    }
    final title = (w['title']?.isNotEmpty ?? false)
        ? w['title']!
        : (w['name']?.isNotEmpty ?? false)
            ? w['name']!
            : w['folder']!;
    LogService.instance.add('RemoteApi: launching ${w['id']}');
    await nav.push(MaterialPageRoute(
      builder: (_) => WappPage(wappDir: w!['dir']!, title: title),
    ));
    return true;
  }
}
