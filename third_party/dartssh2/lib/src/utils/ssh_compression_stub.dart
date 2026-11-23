import 'package:dartssh2/src/algorithm/ssh_compression_type.dart';
import 'package:dartssh2/src/utils/ssh_compression.dart';

const List<SSHCompressionType> defaultCompressionAlgorithms = [
  SSHCompressionType.none,
];

SSHPacketCompressor? createCompressor(SSHCompressionType type) => null;

SSHPacketDecompressor? createDecompressor(SSHCompressionType type) => null;
