import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:orchid/api/preferences/user_preferences.dart';
import 'package:orchid/util/hex.dart';
import 'package:pointycastle/api.dart';
import 'package:pointycastle/digests/sha3.dart';
import 'package:pointycastle/ecc/api.dart';
import 'package:pointycastle/ecc/curves/secp256k1.dart';
import 'package:pointycastle/key_generators/api.dart';
import 'package:pointycastle/key_generators/ec_key_generator.dart';
import 'package:pointycastle/src/utils.dart' as decode;

class Crypto {
  static final ECDomainParameters curve = ECCurve_secp256k1();

  /// Generate an Ethereum KeyPair and corresponding address.
  static EthereumKeyPair generateKeyPair() {
    // Generate a keypair using Dart's secure random source.
    final generator = ECKeyGenerator();
    final params = ECKeyGeneratorParameters(curve);
    generator.init(ParametersWithRandom(params, DartSecureRandom()));
    final key = generator.generateKeyPair();
    final BigInt privateKey = (key.privateKey as ECPrivateKey).d;
    return fromPrivateKey(privateKey);
  }

  static EthereumKeyPair fromPrivateKey(BigInt privateKey) {
    final ECDomainParameters curve = ECCurve_secp256k1();

    final ECPoint publicKeyPoint = curve.G * privateKey; // EC scalar multiply

    // X9.62 encoded uncompressed ECPoint is just the prefix value '4' followed by x, y.
    final encoded = publicKeyPoint.getEncoded(false).buffer;
    // Remove the prefix byte
    final publicKey = Uint8List.view(encoded, 1);

    // Derive the Ethereum address from the public key
    final SHA3Digest sha3digest = SHA3Digest(256 /*bits*/);
    final hashed = sha3digest.process(publicKey);
    final ethereumAddress = Uint8List.view(
        hashed.buffer, 32 /*bytes*/ - 20 /*eth address length bytes*/);

    return new EthereumKeyPair(
        private: privateKey,
        public: toHex(publicKey),
        address: toHex(ethereumAddress));
  }

  static String toHex(Uint8List bytes) {
    var result = new StringBuffer('0x');
    bytes.forEach((val) {
      var pad = val < 16 ? '0' : '';
      result.write('$pad${val.toRadixString(16)}');
    });
    return result.toString();
  }

  /// Parse the string with an optional 0x prefix and return the BigInt or
  /// throw an exception if invalid.
  static BigInt parseEthereumPrivateKey(String text) {
    try {
      if (text.toLowerCase().startsWith('0x')) {
        text = text.substring(2);
      }
      var keyInt = BigInt.parse(text, radix: 16);
      if (keyInt > BigInt.from(0) &&
          keyInt < ((BigInt.from(1) << 256) - BigInt.from(1))) {
        return keyInt;
      } else {
        throw Exception("invalid range");
      }
    } catch (err) {
      throw Exception("invalid key");
    }
  }

}

class EthereumKeyPair {
  // The EC private key
  final BigInt private;

  // The EC public key
  final String public;

  // The ethereum address for this keypair
  final String address;

  const EthereumKeyPair({this.private, this.public, this.address});
}

class DartSecureRandom implements SecureRandom {
  Random random;

  DartSecureRandom() {
    // Dart's cryptographic random number source
    this.random = Random.secure();
  }

  @override
  int nextUint8() => random.nextInt(1 << 8);

  @override
  int nextUint16() => random.nextInt(1 << 16);

  @override
  int nextUint32() => random.nextInt(1 << 32);

  @override
  String get algorithmName => 'dart';

  // Inspired by code from Simon Binder (simolus3/web3dart)
  @override
  BigInt nextBigInteger(int bitLength) {
    final byteLength = bitLength ~/ 8;
    final remainderBits = bitLength % 8;
    final part1 = decode.decodeBigInt(nextBytes(byteLength));
    final part2 = BigInt.from(random.nextInt(1 << remainderBits));
    return part1 + (part2 << (byteLength * 8));
  }

  @override
  Uint8List nextBytes(int count) {
    var bytes = List<int>.generate(count, (_) => nextUint8());
    return Uint8List.fromList(bytes);
  }

  @override
  void seed(CipherParameters params) {
    throw Exception("Dart secure random is already seeded.");
  }
}

class StoredEthereumKey {
  // A locally unique id for referencing this key in the persistence layer.
  final String uid;

  // The time at which this key was stored.
  final DateTime time;

  // True if this key was imported.  False if it was generated by us.
  final bool imported;

  // The EC private key
  final BigInt private;

  StoredEthereumKey(
      {String uid,
      @required this.time,
      @required this.imported,
      @required this.private})
      : this.uid = uid ?? time.millisecondsSinceEpoch.toString();

  EthereumKeyPair keys() {
    return Crypto.fromPrivateKey(private);
  }

  StoredEthereumKeyRef ref() {
    return StoredEthereumKeyRef.from(uid);
  }

  StoredEthereumKey.fromJson(Map<String, dynamic> json)
      : this.uid = json['uuid'] ?? json['time'].toString(),
        this.time = DateTime.fromMillisecondsSinceEpoch(json['time']),
        this.imported = json['imported'],
        this.private = BigInt.parse(json['private']);

  Map<String, dynamic> toJson() => {
        'uuid': uid,
        'time': time.millisecondsSinceEpoch,
        'imported': imported,
        'private': private.toString()
      };
}

// A simple referential value by uid.
// Note: We can do more with caching here if needed.
class StoredEthereumKeyRef {
  String keyUid;

  StoredEthereumKeyRef.from(String keyUid) {
    if (keyUid == null) {
      throw Exception("null key");
    }
    this.keyUid = keyUid;
  }

  // Resolve the reference
  Future<StoredEthereumKey> get() async {
    var keys = await UserPreferences().getKeys();
    try {
      return getFrom(keys);
    } catch(err) {
      throw Exception("get key error: $err");
    }
  }

  StoredEthereumKey getFrom(List<StoredEthereumKey> keys) {
    try {
      return keys.firstWhere((key) {
        return key.uid == keyUid;
      });
    } catch(err) {
      throw Exception("getFrom(key) error: $err");
    }
  }

  @override
  String toString() {
    return keyUid;
  }
}

class EthereumAddress {
  BigInt value;

  EthereumAddress(BigInt value) {
    // Allow the string parser to validate.
    this.value = parse(value.toRadixString(16));
  }

  EthereumAddress.from(String text) {
    this.value = parse(text);
  }

  // TODO: EIP55
  // Display the optionally prefixed 40 char hex address.
  @override
  String toString({bool prefix: true}) {
    if (value == null) {
      throw Exception("invalid bigint");
    }
    return (prefix ? "0x" : "") + value.toRadixString(16).padLeft(40, '0');
  }

  // TODO: EIP55
  static BigInt parse(String text) {
    if (text == null) {
      throw Exception("invalid, null");
    }
    text = Hex.removePrefix(text);
    if (text.length != 40) {
      throw Exception("invalid, length");
    }
    try {
      var val = BigInt.parse(text, radix: 16);
      if (val < BigInt.from(0)) {
        throw Exception("invalid, range");
      }
      return val;
    } catch (err) {
      print(err);
      throw Exception("invalid, value");
    }
  }
}