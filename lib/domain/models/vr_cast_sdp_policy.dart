import 'dart:convert';

import '../../utils/constants/vr_cast_signaling_constants.dart';

/// Strict policy for the initial LAN, video-only spectator protocol.
/// This is intentionally narrower than general-purpose WebRTC: no STUN/TURN,
/// public/IPv6/mDNS ICE destinations, audio, data channels or renegotiation.
abstract final class VrCastSdpPolicy {
  static String sanitize(String sdp, {required bool offer}) {
    if (sdp.isEmpty ||
        utf8.encode(sdp).length > VrCastSignalingConstants.maxSdpBytes ||
        sdp.contains('\u0000')) {
      throw const VrCastSdpException('invalid-description');
    }
    final lines = sdp.trim().split(RegExp(r'\r?\n'));
    if (lines.length > 512 ||
        lines.first != 'v=0' ||
        lines.any((line) => line.length > 2048 || line.contains('\r'))) {
      throw const VrCastSdpException('invalid-description');
    }
    final sections = <_MediaSection>[];
    _MediaSection? section;
    var sessionDirection = 'sendrecv';
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (line.startsWith('m=')) {
        final fields = line.substring(2).split(RegExp(r'\s+'));
        if (fields.length < 4) {
          throw const VrCastSdpException('invalid-media');
        }
        final port = int.tryParse(fields[1]);
        if (port == null || port < 0 || port > 65535) {
          throw const VrCastSdpException('invalid-media');
        }
        section = _MediaSection(
          fields.first,
          port,
          fields[2],
          sessionDirection,
        );
        sections.add(section);
      } else if (_directions.contains(line)) {
        if (section == null) {
          sessionDirection = line.substring(2);
        } else {
          if (section.hasExplicitDirection) {
            throw const VrCastSdpException('ambiguous-media');
          }
          section.direction = line.substring(2);
          section.hasExplicitDirection = true;
        }
      } else if (line == 'a=rtcp-mux') {
        section?.rtcpMux = true;
      }
    }
    final active = sections.where(
      (s) => s.port != 0 && s.direction != 'inactive',
    );
    if (active.length != 1 ||
        active.single.kind != 'video' ||
        sections.any((s) => s.kind != 'video' && s.port != 0)) {
      throw const VrCastSdpException('video-only-required');
    }
    final video = active.single;
    if (video.protocol != 'UDP/TLS/RTP/SAVPF' ||
        video.direction != (offer ? 'recvonly' : 'sendonly') ||
        !video.rtcpMux) {
      throw const VrCastSdpException('unsupported-video-direction');
    }
    final sanitized = <String>[];
    var sectionIndex = -1;
    var privateCandidates = 0;
    for (final line in lines) {
      if (line.startsWith('m=')) sectionIndex++;
      if (line.startsWith('a=candidate:')) {
        if (sectionIndex < 0 || !identical(sections[sectionIndex], video)) {
          continue;
        }
        final candidate = _privateHostCandidate(line);
        if (candidate != null) {
          sanitized.add(candidate);
          privateCandidates++;
        }
      } else if (line.startsWith('a=remote-candidates:')) {
        // Do not permit a proposed selected-pair address outside our policy.
        continue;
      } else if (line.startsWith('c=')) {
        sanitized.add('c=IN IP4 0.0.0.0');
      } else if (line.startsWith('a=rtcp:')) {
        sanitized.add('a=rtcp:9 IN IP4 0.0.0.0');
      } else {
        sanitized.add(line);
      }
    }
    if (privateCandidates == 0) {
      throw const VrCastSdpException('private-lan-candidate-required');
    }
    return '${sanitized.join('\r\n')}\r\n';
  }

  static const _directions = {
    'a=recvonly',
    'a=sendonly',
    'a=sendrecv',
    'a=inactive',
  };

  static String? _privateHostCandidate(String line) {
    final fields = line.substring('a=candidate:'.length).split(RegExp(r'\s+'));
    if (fields.length < 8 ||
        fields[0].isEmpty ||
        fields[1] != '1' ||
        fields[6] != 'typ' ||
        fields[7] != 'host' ||
        !isPrivateV4(fields[4])) {
      return null;
    }
    final transport = fields[2].toLowerCase();
    final priority = int.tryParse(fields[3]);
    final port = int.tryParse(fields[5]);
    if ((transport != 'udp' && transport != 'tcp') ||
        priority == null ||
        priority < 0 ||
        priority > 0xffffffff ||
        port == null ||
        port < 1 ||
        port > 65535) {
      return null;
    }
    var suffix = '';
    if (transport == 'tcp') {
      final index = fields.indexOf('tcptype', 8);
      if (index < 0 ||
          index + 1 >= fields.length ||
          !const {'active', 'passive', 'so'}.contains(fields[index + 1])) {
        return null;
      }
      suffix = ' tcptype ${fields[index + 1]}';
    }
    // Remove optional extensions (including related addresses). The eight
    // required fields and TCP mode are sufficient for direct host candidates.
    return 'a=candidate:${fields.take(8).join(' ')}$suffix';
  }

  static bool isPrivateV4(String address) {
    final fields = address.split('.');
    if (fields.length != 4) return false;
    final octets = <int>[];
    for (final field in fields) {
      final value = int.tryParse(field);
      if (value == null || value < 0 || value > 255 || '$value' != field) {
        return false;
      }
      octets.add(value);
    }
    return octets[0] == 10 ||
        (octets[0] == 172 && octets[1] >= 16 && octets[1] <= 31) ||
        (octets[0] == 192 && octets[1] == 168);
  }
}

class _MediaSection {
  _MediaSection(this.kind, this.port, this.protocol, this.direction);
  final String kind;
  final int port;
  final String protocol;
  String direction;
  bool hasExplicitDirection = false;
  bool rtcpMux = false;
}

class VrCastSdpException implements Exception {
  const VrCastSdpException(this.code);
  final String code;
  @override
  String toString() => 'Cast video description rejected: $code.';
}
