// Phase G — copy ABIs out of contracts/abi/ into lib/assets/abi/.
//
// Why this exists: the Flutter app loads ABIs through DefaultAssetBundle
// at runtime (see lib/services/chain_client.dart::_AbiCache). The
// canonical source is contracts/abi/*.json which the Hardhat compile
// pipeline writes after every `npx hardhat compile`. Without this sync
// step, `flutter run` would lag the contract definition by however long
// it takes someone to remember to copy the JSONs over.
//
// Usage:
//   dart run scripts/sync_abi.dart
//   # or via the justfile
//   just sync-abi

import 'dart:io';

const _src = 'contracts/abi';
const _dst = 'lib/assets/abi';

void main(List<String> args) {
  final srcDir = Directory(_src);
  if (!srcDir.existsSync()) {
    stderr.writeln('No $_src directory found. Run `npx hardhat compile` first.');
    exit(1);
  }
  Directory(_dst).createSync(recursive: true);
  var copied = 0;
  for (final entity in srcDir.listSync()) {
    if (entity is! File || !entity.path.endsWith('.json')) continue;
    final fileName = entity.uri.pathSegments.last;
    final dstPath = '$_dst/$fileName';
    entity.copySync(dstPath);
    stdout.writeln('  $fileName  →  $dstPath');
    copied++;
  }
  stdout.writeln('synced $copied ABI(s) from $_src to $_dst');
}
