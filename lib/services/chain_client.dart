import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import 'package:web3dart/web3dart.dart';
import 'package:web3dart/crypto.dart' show bytesToHex;

import '../core/constants/chain_config.dart';
import '../models/on_chain_activity.dart';

class _AbiCache {
  static final Map<String, String> _cache = {};

  static Future<String> load(String name) async {
    final cached = _cache[name];
    if (cached != null) return cached;
    final raw = await rootBundle.loadString('lib/assets/abi/$name.json');
    // Hardhat artifacts are `{ "contractName", "abi": [...] }`; web3dart wants
    // the ABI array JSON string.
    final decoded = jsonDecode(raw);
    final String abiJson;
    if (decoded is List) {
      abiJson = raw;
    } else if (decoded is Map && decoded['abi'] is List) {
      abiJson = jsonEncode(decoded['abi']);
    } else {
      throw ChainClientException('Unexpected ABI format for $name');
    }
    _cache[name] = abiJson;
    return abiJson;
  }
}

class ChainClientException implements Exception {
  final String reason;
  const ChainClientException(this.reason);
  @override
  String toString() => 'ChainClientException: $reason';
}

class WrongNetworkException implements Exception {
  final BigInt detectedChainId;
  const WrongNetworkException(this.detectedChainId);

  static int get expectedChainId => ChainConfig.chainId;

  @override
  String toString() =>
      'WrongNetworkException: expected chain $expectedChainId; '
      'RPC reports $detectedChainId';
}

class TxResult {
  final BigInt? sessionId;
  final String txHash;
  const TxResult({this.sessionId, required this.txHash});
}

/// Hardcoded Polygon Amoy gas budget for demo pre-flight (MATIC, not wei).
const double kEstimatedGasMatic = 0.05;

BigInt get kEstimatedGasWei =>
    (BigInt.from(5) * BigInt.from(10).pow(16)); // 0.05 * 1e18

BigInt get maxUint256 => BigInt.parse(
      '115792089237316195423570985008687907853269984665640564039457584007913129639935',
    );

class ChainClient {
  ChainClient({
    String? rpcUrl,
    http.Client? httpClient,
    int? chainId,
    this.testSkipChainCheck = false,
  })  : _httpClient = httpClient ?? http.Client(),
        rpcUrl = rpcUrl ?? ChainConfig.polygonAmoyRpcUrl,
        expectedChainId = chainId ?? ChainConfig.polygonAmoyChainId {
    _client = Web3Client(this.rpcUrl, _httpClient);
  }

  final http.Client _httpClient;
  final String rpcUrl;
  final int expectedChainId;
  final bool testSkipChainCheck;
  late final Web3Client _client;

  Future<void> _ensureNetwork() async {
    if (testSkipChainCheck) return;
    final id = await _withRetry(
      () => _client.getChainId(),
      label: 'getChainId',
    );
    if (id != BigInt.from(expectedChainId)) {
      throw WrongNetworkException(id);
    }
  }

  Future<BigInt> getNativeBalance(EthereumAddress address) async {
    await _ensureNetwork();
    return _withRetry(() async {
      final amount = await _client.getBalance(address);
      return amount.getInWei;
    }, label: 'getNativeBalance');
  }

  Future<BigInt?> getTokenBalance(
    EthereumAddress holder,
    EthereumAddress? token,
  ) async {
    if (token == null) return null;
    await _ensureNetwork();
    return _withRetry(() async {
      final abi = await _AbiCache.load('StrataToken');
      final contract = DeployedContract(
        ContractAbi.fromJson(abi, 'StrataToken'),
        token,
      );
      final fn = contract.function('balanceOf');
      final result = await _client.call(
        contract: contract,
        function: fn,
        params: [holder],
      );
      if (result.isEmpty) {
        throw const ChainClientException('balanceOf returned no values');
      }
      return result.first as BigInt;
    }, label: 'getTokenBalance');
  }

  Future<BigInt> getTokenAllowance({
    required EthereumAddress holder,
    required EthereumAddress token,
    required EthereumAddress spender,
  }) async {
    await _ensureNetwork();
    return _withRetry(() async {
      final abi = await _AbiCache.load('StrataToken');
      final contract = DeployedContract(
        ContractAbi.fromJson(abi, 'StrataToken'),
        token,
      );
      final fn = contract.function('allowance');
      final result = await _client.call(
        contract: contract,
        function: fn,
        params: [holder, spender],
      );
      if (result.isEmpty) {
        throw const ChainClientException('allowance returned no values');
      }
      return result.first as BigInt;
    }, label: 'allowance');
  }

  Future<int> getNonce(EthereumAddress address) async {
    await _ensureNetwork();
    return _withRetry(() async {
      return _client.getTransactionCount(address);
    }, label: 'getNonce');
  }

  Future<String> approveToken({
    required EthPrivateKey credentials,
    required EthereumAddress tokenAddress,
    required EthereumAddress spender,
    required BigInt amount,
    EtherAmount? gasPrice,
  }) async {
    await _ensureNetwork();
    final abi = await _AbiCache.load('StrataToken');
    final contract = DeployedContract(
      ContractAbi.fromJson(abi, 'StrataToken'),
      tokenAddress,
    );
    final fn = contract.function('approve');
    final tx = Transaction.callContract(
      contract: contract,
      function: fn,
      parameters: [spender, amount],
      gasPrice: gasPrice,
    );
    final hash = await _withRetry(
      () => _client.sendTransaction(credentials, tx, chainId: expectedChainId),
      label: 'approveToken',
    );
    await _waitForReceipt(hash, label: 'approveToken');
    return hash;
  }

  Future<String> claimFaucet({
    required EthPrivateKey credentials,
    required EthereumAddress tokenAddress,
  }) async {
    await _ensureNetwork();
    final abi = await _AbiCache.load('StrataToken');
    final contract = DeployedContract(
      ContractAbi.fromJson(abi, 'StrataToken'),
      tokenAddress,
    );
    final fn = contract.function('faucet');
    final tx = Transaction.callContract(
      contract: contract,
      function: fn,
      parameters: <dynamic>[],
    );
    final hash = await _withRetry(
      () => _client.sendTransaction(credentials, tx, chainId: expectedChainId),
      label: 'faucet',
    );
    await _waitForReceipt(hash, label: 'faucet');
    return hash;
  }

  Future<String> sendOpenSessionTx({
    required EthPrivateKey credentials,
    required EthereumAddress escrowAddress,
    required EthereumAddress hostAddress,
    required BigInt amount,
    required String sessionRefHex,
    EtherAmount? gasPrice,
  }) async {
    await _ensureNetwork();
    final abi = await _AbiCache.load('SessionEscrow');
    final contract = DeployedContract(
      ContractAbi.fromJson(abi, 'SessionEscrow'),
      escrowAddress,
    );
    final fn = contract.function('openSession');
    final ref = _hexToBytes32(sessionRefHex);
    final tx = Transaction.callContract(
      contract: contract,
      function: fn,
      parameters: [hostAddress, amount, ref],
      gasPrice: gasPrice,
    );
    final hash = await _withRetry(
      () =>
          _client.sendTransaction(credentials, tx, chainId: expectedChainId),
      label: 'openSession_send',
    );
    return hash;
  }

  /// Confirms inclusion and decodes SessionOpened(sessionId,...).
  Future<TxResult> verifyOpenSessionReceipt({
    required String txHash,
    required EthereumAddress escrowAddress,
    required String sessionRefHex,
    int confirmations = 1,
  }) async {
    await _ensureNetwork();
    final receipt = await waitForReceipt(
      txHash,
      label: 'openSession_confirm',
      confirmations: confirmations,
    );
    final abi = await _AbiCache.load('SessionEscrow');
    final contract = DeployedContract(
      ContractAbi.fromJson(abi, 'SessionEscrow'),
      escrowAddress,
    );
    final opened = contract.event('SessionOpened');
    final eventSig = bytesToHex(
      opened.signature,
      include0x: true,
      forcePadLength: 64,
    ).toLowerCase();
    final escrowLower = escrowAddress.hex.toLowerCase();
    final expectedRef = _hexToBytes32(sessionRefHex);
    BigInt? sessionId;
    for (final log in receipt.logs) {
      final ethAddr = log.address;
      if (ethAddr == null) continue;
      final logAddr = ethAddr.hex.toLowerCase();
      if (logAddr != escrowLower) continue;
      final rawTopics = log.topics;
      if (rawTopics == null || rawTopics.isEmpty) continue;
      final firstTopic = rawTopics.first;
      if (firstTopic == null) continue;
      if (firstTopic.toLowerCase() != eventSig) continue;
      final topics =
          rawTopics.whereType<String>().toList(growable: false);
      try {
        final decoded = opened.decodeResults(
          topics,
          log.data ?? '0x',
        );
        sessionId = decoded[0] as BigInt;
        final gotRefRaw = decoded[4];
        final gotBytes = gotRefRaw is Uint8List
            ? gotRefRaw
            : (gotRefRaw is BigInt ? _bigIntToUint8Array32(gotRefRaw) : null);
        if (gotBytes == null || gotBytes.length != 32) {
          throw const ChainClientException('SessionOpened ref decode');
        }
        for (var i = 0; i < 32; i++) {
          if (gotBytes[i] != expectedRef[i]) {
            sessionId = null;
            break;
          }
        }
        if (sessionId != null) break;
        sessionId = null;
      } catch (_) {
        sessionId = null;
      }
    }
    if (sessionId == null) {
      throw const ChainClientException(
        'SessionOpened event not found for expected sessionRef',
      );
    }
    return TxResult(sessionId: sessionId, txHash: txHash);
  }

  Future<TxResult> openSession({
    required EthPrivateKey credentials,
    required EthereumAddress escrowAddress,
    required EthereumAddress hostAddress,
    required BigInt amount,
    required String sessionRefHex,
    EtherAmount? gasPrice,
  }) async {
    final hash = await sendOpenSessionTx(
      credentials: credentials,
      escrowAddress: escrowAddress,
      hostAddress: hostAddress,
      amount: amount,
      sessionRefHex: sessionRefHex,
      gasPrice: gasPrice,
    );
    return verifyOpenSessionReceipt(
      txHash: hash,
      escrowAddress: escrowAddress,
      sessionRefHex: sessionRefHex,
    );
  }

  Future<String> closeSession({
    required EthPrivateKey credentials,
    required EthereumAddress escrowAddress,
    required BigInt onChainSessionId,
    required BigInt bytesConsumed,
    required BigInt quotaBytes,
    required Uint8List hostSig,
  }) async {
    await _ensureNetwork();
    final abi = await _AbiCache.load('SessionEscrow');
    final contract = DeployedContract(
      ContractAbi.fromJson(abi, 'SessionEscrow'),
      escrowAddress,
    );
    final fn = contract.function('closeSession');
    final tx = Transaction.callContract(
      contract: contract,
      function: fn,
      parameters: [
        onChainSessionId,
        bytesConsumed,
        quotaBytes,
        hostSig,
      ],
    );
    final hash = await _withRetry(
      () => _client.sendTransaction(credentials, tx, chainId: expectedChainId),
      label: 'closeSession',
    );
    await _waitForReceipt(hash, label: 'closeSession');
    return hash;
  }

  Future<String> disputeSession({
    required EthPrivateKey credentials,
    required EthereumAddress escrowAddress,
    required BigInt onChainSessionId,
  }) async {
    await _ensureNetwork();
    final abi = await _AbiCache.load('SessionEscrow');
    final contract = DeployedContract(
      ContractAbi.fromJson(abi, 'SessionEscrow'),
      escrowAddress,
    );
    final fn = contract.function('disputeSession');
    final tx = Transaction.callContract(
      contract: contract,
      function: fn,
      parameters: [onChainSessionId],
    );
    final hash = await _withRetry(
      () => _client.sendTransaction(credentials, tx, chainId: expectedChainId),
      label: 'disputeSession',
    );
    await _waitForReceipt(hash, label: 'disputeSession');
    return hash;
  }

  /// Loads STRATA `Transfer` events + SessionEscrow `PaymentSettled` for [wallet].
  ///
  /// Queries a recent block window (chunked) via `eth_getLogs`. Returns newest
  /// first. Timestamps are filled from block headers when available.
  Future<List<OnChainActivity>> fetchWalletHistory({
    required EthereumAddress wallet,
    EthereumAddress? tokenAddress,
    EthereumAddress? escrowAddress,
    int lookbackBlocks = 50000,
    int chunkSize = 2000,
  }) async {
    await _ensureNetwork();
    final token = tokenAddress ??
        (ChainConfig.strataTokenContract.isEmpty
            ? null
            : EthereumAddress.fromHex(ChainConfig.strataTokenContract));
    final escrow = escrowAddress ??
        (ChainConfig.sessionEscrowContract.isEmpty
            ? null
            : EthereumAddress.fromHex(ChainConfig.sessionEscrowContract));
    if (token == null && escrow == null) {
      return const [];
    }

    final latest = await _withRetry(
      () => _client.getBlockNumber(),
      label: 'getBlockNumber',
    );
    final from = latest > lookbackBlocks ? latest - lookbackBlocks : 0;
    final activities = <OnChainActivity>[];

    if (token != null) {
      final tokenAbi = await _AbiCache.load('StrataToken');
      final tokenContract = DeployedContract(
        ContractAbi.fromJson(tokenAbi, 'StrataToken'),
        token,
      );
      final transfer = tokenContract.event('Transfer');
      final transferSig = bytesToHex(
        transfer.signature,
        include0x: true,
        forcePadLength: 64,
      ).toLowerCase();
      final walletTopic = _addressTopic(wallet);

      for (var start = from; start <= latest; start += chunkSize) {
        final end = (start + chunkSize - 1).clamp(0, latest);
        final outgoing = await _getLogsChunk(
          address: token,
          fromBlock: start,
          toBlock: end,
          topics: [
            [transferSig],
            [walletTopic],
            [],
          ],
        );
        final incoming = await _getLogsChunk(
          address: token,
          fromBlock: start,
          toBlock: end,
          topics: [
            [transferSig],
            [],
            [walletTopic],
          ],
        );
        for (final log in [...outgoing, ...incoming]) {
          final parsed = _parseTransferLog(
            log: log,
            transfer: transfer,
            wallet: wallet,
          );
          if (parsed != null) activities.add(parsed);
        }
      }
    }

    if (escrow != null) {
      final escrowAbi = await _AbiCache.load('SessionEscrow');
      final escrowContract = DeployedContract(
        ContractAbi.fromJson(escrowAbi, 'SessionEscrow'),
        escrow,
      );
      final settled = escrowContract.event('PaymentSettled');
      final settledSig = bytesToHex(
        settled.signature,
        include0x: true,
        forcePadLength: 64,
      ).toLowerCase();
      final walletTopic = _addressTopic(wallet);

      for (var start = from; start <= latest; start += chunkSize) {
        final end = (start + chunkSize - 1).clamp(0, latest);
        // As host (topic2) or as guest (topic3).
        final asHost = await _getLogsChunk(
          address: escrow,
          fromBlock: start,
          toBlock: end,
          topics: [
            [settledSig],
            [],
            [walletTopic],
            [],
          ],
        );
        final asGuest = await _getLogsChunk(
          address: escrow,
          fromBlock: start,
          toBlock: end,
          topics: [
            [settledSig],
            [],
            [],
            [walletTopic],
          ],
        );
        for (final log in [...asHost, ...asGuest]) {
          final parsed = _parsePaymentSettledLog(
            log: log,
            settled: settled,
            wallet: wallet,
          );
          if (parsed != null) activities.add(parsed);
        }
      }
    }

    // Deduplicate identical (txHash, kind, direction, amount) rows.
    final seen = <String>{};
    final unique = <OnChainActivity>[];
    for (final a in activities) {
      final key =
          '${a.txHash}|${a.kind.name}|${a.direction.name}|${a.amountWei}|${a.sessionId}';
      if (seen.add(key)) unique.add(a);
    }

    await _attachBlockTimestamps(unique);

    unique.sort((a, b) {
      final ba = a.blockNumber ?? 0;
      final bb = b.blockNumber ?? 0;
      if (ba != bb) return bb.compareTo(ba);
      return b.txHash.compareTo(a.txHash);
    });
    return unique;
  }

  Future<List<FilterEvent>> _getLogsChunk({
    required EthereumAddress address,
    required int fromBlock,
    required int toBlock,
    required List<List<String?>> topics,
  }) {
    return _withRetry(
      () => _client.getLogs(
        FilterOptions(
          fromBlock: BlockNum.exact(fromBlock),
          toBlock: BlockNum.exact(toBlock),
          address: address,
          topics: topics,
        ),
      ),
      label: 'eth_getLogs',
    );
  }

  String _addressTopic(EthereumAddress addr) {
    final hex = addr.hexNo0x.toLowerCase().padLeft(64, '0');
    return '0x$hex';
  }

  OnChainActivity? _parseTransferLog({
    required FilterEvent log,
    required ContractEvent transfer,
    required EthereumAddress wallet,
  }) {
    final topics = log.topics?.whereType<String>().toList(growable: false);
    if (topics == null || topics.length < 3) return null;
    try {
      final decoded = transfer.decodeResults(topics, log.data ?? '0x');
      final from = decoded[0] as EthereumAddress;
      final to = decoded[1] as EthereumAddress;
      final value = decoded[2] as BigInt;
      final walletHex = wallet.hex.toLowerCase();
      final fromMe = from.hex.toLowerCase() == walletHex;
      final toMe = to.hex.toLowerCase() == walletHex;
      if (!fromMe && !toMe) return null;
      // Self-transfer: treat as outgoing once.
      final direction =
          toMe && !fromMe ? OnChainDirection.incoming : OnChainDirection.outgoing;
      final counterparty = fromMe ? to.hex : from.hex;
      return OnChainActivity(
        kind: OnChainActivityKind.tokenTransfer,
        direction: direction,
        status: OnChainTxStatus.confirmed,
        txHash: log.transactionHash ?? '',
        amountWei: value,
        tokenSymbol: 'STRATA',
        blockNumber: log.blockNum,
        counterparty: counterparty,
      );
    } catch (_) {
      return null;
    }
  }

  OnChainActivity? _parsePaymentSettledLog({
    required FilterEvent log,
    required ContractEvent settled,
    required EthereumAddress wallet,
  }) {
    final topics = log.topics?.whereType<String>().toList(growable: false);
    if (topics == null || topics.length < 4) return null;
    try {
      final decoded = settled.decodeResults(topics, log.data ?? '0x');
      final sessionId = decoded[0] as BigInt;
      final host = decoded[1] as EthereumAddress;
      final hostPayment = decoded[2] as BigInt;
      final guest = decoded[3] as EthereumAddress;
      final refund = decoded[4] as BigInt;
      final walletHex = wallet.hex.toLowerCase();
      final isHost = host.hex.toLowerCase() == walletHex;
      final isGuest = guest.hex.toLowerCase() == walletHex;
      if (!isHost && !isGuest) return null;
      if (isHost) {
        return OnChainActivity(
          kind: OnChainActivityKind.paymentSettled,
          direction: OnChainDirection.settlement,
          status: OnChainTxStatus.confirmed,
          txHash: log.transactionHash ?? '',
          amountWei: hostPayment,
          tokenSymbol: 'STRATA',
          blockNumber: log.blockNum,
          counterparty: guest.hex,
          sessionId: sessionId,
          refundWei: refund,
        );
      }
      // Guest view: refund returned (if any) as incoming; host payment as context.
      return OnChainActivity(
        kind: OnChainActivityKind.paymentSettled,
        direction: refund > BigInt.zero
            ? OnChainDirection.incoming
            : OnChainDirection.outgoing,
        status: OnChainTxStatus.confirmed,
        txHash: log.transactionHash ?? '',
        amountWei: refund > BigInt.zero ? refund : hostPayment,
        tokenSymbol: 'STRATA',
        blockNumber: log.blockNum,
        counterparty: host.hex,
        sessionId: sessionId,
        refundWei: refund,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _attachBlockTimestamps(List<OnChainActivity> items) async {
    final blocks = <int>{};
    for (final a in items) {
      final b = a.blockNumber;
      if (b != null) blocks.add(b);
    }
    if (blocks.isEmpty) return;
    final times = <int, DateTime>{};
    for (final b in blocks) {
      try {
        final info = await _client.getBlockInformation(
          blockNumber: '0x${b.toRadixString(16)}',
          isContainFullObj: false,
        );
        times[b] = info.timestamp.toUtc();
      } catch (_) {
        // Timestamp is optional; skip on RPC gaps.
      }
    }
    for (var i = 0; i < items.length; i++) {
      final a = items[i];
      final b = a.blockNumber;
      if (b == null || !times.containsKey(b)) continue;
      items[i] = OnChainActivity(
        kind: a.kind,
        direction: a.direction,
        status: a.status,
        txHash: a.txHash,
        amountWei: a.amountWei,
        tokenSymbol: a.tokenSymbol,
        blockNumber: a.blockNumber,
        timestamp: times[b],
        counterparty: a.counterparty,
        sessionId: a.sessionId,
        refundWei: a.refundWei,
      );
    }
  }

  Future<TransactionReceipt> waitForReceipt(
    String hash, {
    required String label,
    int confirmations = 1,
    Duration pollInterval = const Duration(seconds: 2),
    Duration timeout = const Duration(minutes: 2),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final receipt = await _client.getTransactionReceipt(hash);
      if (receipt != null) {
        if (receipt.status != true) {
          throw ChainClientException('$label reverted on-chain: $hash');
        }
        return receipt;
      }
      await Future<void>.delayed(pollInterval);
    }
    throw ChainClientException('$label timed out waiting for receipt $hash');
  }

  Future<TransactionReceipt> _waitForReceipt(
    String hash, {
    required String label,
    Duration pollInterval = const Duration(seconds: 2),
    Duration timeout = const Duration(minutes: 2),
  }) {
    return waitForReceipt(
      hash,
      label: label,
      pollInterval: pollInterval,
      timeout: timeout,
    );
  }

  Future<T> _withRetry<T>(
    Future<T> Function() task, {
    required String label,
  }) async {
    try {
      return await task();
    } on WrongNetworkException {
      rethrow;
    } catch (_) {
      await Future<void>.delayed(const Duration(seconds: 2));
      try {
        return await task();
      } on WrongNetworkException {
        rethrow;
      } catch (e) {
        throw ChainClientException('$label failed after retry: ${e.runtimeType}');
      }
    }
  }

  Uint8List _bigIntToUint8Array32(BigInt n) {
    final b = Uint8List(32);
    var val = n;
    for (var i = 31; i >= 0; i--) {
      b[i] = (val & BigInt.from(0xff)).toInt();
      val = val >> 8;
    }
    return b;
  }

  Uint8List _hexToBytes32(String hex) {
    var clean = hex.startsWith('0x') ? hex.substring(2) : hex;
    if (clean.length > 64) {
      throw ChainClientException(
        'sessionRef must be <= 32 bytes; got ${clean.length ~/ 2}',
      );
    }
    clean = clean.padLeft(64, '0');
    final bytes = Uint8List(32);
    for (var i = 0; i < 32; i++) {
      bytes[i] = int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return bytes;
  }

  void dispose() {
    _client.dispose();
    _httpClient.close();
  }
}
