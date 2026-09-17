// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'database.dart';

// ignore_for_file: type=lint
class $SshKeysTable extends SshKeys with TableInfo<$SshKeysTable, SshKey> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SshKeysTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    additionalChecks: GeneratedColumn.checkTextLength(
      minTextLength: 1,
      maxTextLength: 255,
    ),
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _keyTypeMeta = const VerificationMeta(
    'keyType',
  );
  @override
  late final GeneratedColumn<String> keyType = GeneratedColumn<String>(
    'key_type',
    aliasedName,
    false,
    additionalChecks: GeneratedColumn.checkTextLength(
      minTextLength: 1,
      maxTextLength: 50,
    ),
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _publicKeyMeta = const VerificationMeta(
    'publicKey',
  );
  @override
  late final GeneratedColumn<String> publicKey = GeneratedColumn<String>(
    'public_key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _privateKeyMeta = const VerificationMeta(
    'privateKey',
  );
  @override
  late final GeneratedColumn<String> privateKey = GeneratedColumn<String>(
    'private_key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _passphraseMeta = const VerificationMeta(
    'passphrase',
  );
  @override
  late final GeneratedColumn<String> passphrase = GeneratedColumn<String>(
    'passphrase',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _fingerprintMeta = const VerificationMeta(
    'fingerprint',
  );
  @override
  late final GeneratedColumn<String> fingerprint = GeneratedColumn<String>(
    'fingerprint',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
    defaultValue: currentDateAndTime,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    name,
    keyType,
    publicKey,
    privateKey,
    passphrase,
    fingerprint,
    createdAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'ssh_keys';
  @override
  VerificationContext validateIntegrity(
    Insertable<SshKey> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('key_type')) {
      context.handle(
        _keyTypeMeta,
        keyType.isAcceptableOrUnknown(data['key_type']!, _keyTypeMeta),
      );
    } else if (isInserting) {
      context.missing(_keyTypeMeta);
    }
    if (data.containsKey('public_key')) {
      context.handle(
        _publicKeyMeta,
        publicKey.isAcceptableOrUnknown(data['public_key']!, _publicKeyMeta),
      );
    } else if (isInserting) {
      context.missing(_publicKeyMeta);
    }
    if (data.containsKey('private_key')) {
      context.handle(
        _privateKeyMeta,
        privateKey.isAcceptableOrUnknown(data['private_key']!, _privateKeyMeta),
      );
    } else if (isInserting) {
      context.missing(_privateKeyMeta);
    }
    if (data.containsKey('passphrase')) {
      context.handle(
        _passphraseMeta,
        passphrase.isAcceptableOrUnknown(data['passphrase']!, _passphraseMeta),
      );
    }
    if (data.containsKey('fingerprint')) {
      context.handle(
        _fingerprintMeta,
        fingerprint.isAcceptableOrUnknown(
          data['fingerprint']!,
          _fingerprintMeta,
        ),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  SshKey map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SshKey(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      keyType: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}key_type'],
      )!,
      publicKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}public_key'],
      )!,
      privateKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}private_key'],
      )!,
      passphrase: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}passphrase'],
      ),
      fingerprint: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}fingerprint'],
      ),
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}created_at'],
      )!,
    );
  }

  @override
  $SshKeysTable createAlias(String alias) {
    return $SshKeysTable(attachedDatabase, alias);
  }
}

class SshKey extends DataClass implements Insertable<SshKey> {
  /// Unique identifier.
  final int id;

  /// Display name for the key.
  final String name;

  /// Key type (ed25519, rsa, etc.).
  final String keyType;

  /// Public key content.
  final String publicKey;

  /// Private key content (stored encrypted).
  final String privateKey;

  /// Optional passphrase for the key (stored encrypted).
  final String? passphrase;

  /// Key fingerprint for display.
  final String? fingerprint;

  /// Creation timestamp.
  final DateTime createdAt;
  const SshKey({
    required this.id,
    required this.name,
    required this.keyType,
    required this.publicKey,
    required this.privateKey,
    this.passphrase,
    this.fingerprint,
    required this.createdAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['name'] = Variable<String>(name);
    map['key_type'] = Variable<String>(keyType);
    map['public_key'] = Variable<String>(publicKey);
    map['private_key'] = Variable<String>(privateKey);
    if (!nullToAbsent || passphrase != null) {
      map['passphrase'] = Variable<String>(passphrase);
    }
    if (!nullToAbsent || fingerprint != null) {
      map['fingerprint'] = Variable<String>(fingerprint);
    }
    map['created_at'] = Variable<DateTime>(createdAt);
    return map;
  }

  SshKeysCompanion toCompanion(bool nullToAbsent) {
    return SshKeysCompanion(
      id: Value(id),
      name: Value(name),
      keyType: Value(keyType),
      publicKey: Value(publicKey),
      privateKey: Value(privateKey),
      passphrase: passphrase == null && nullToAbsent
          ? const Value.absent()
          : Value(passphrase),
      fingerprint: fingerprint == null && nullToAbsent
          ? const Value.absent()
          : Value(fingerprint),
      createdAt: Value(createdAt),
    );
  }

  factory SshKey.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SshKey(
      id: serializer.fromJson<int>(json['id']),
      name: serializer.fromJson<String>(json['name']),
      keyType: serializer.fromJson<String>(json['keyType']),
      publicKey: serializer.fromJson<String>(json['publicKey']),
      privateKey: serializer.fromJson<String>(json['privateKey']),
      passphrase: serializer.fromJson<String?>(json['passphrase']),
      fingerprint: serializer.fromJson<String?>(json['fingerprint']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'name': serializer.toJson<String>(name),
      'keyType': serializer.toJson<String>(keyType),
      'publicKey': serializer.toJson<String>(publicKey),
      'privateKey': serializer.toJson<String>(privateKey),
      'passphrase': serializer.toJson<String?>(passphrase),
      'fingerprint': serializer.toJson<String?>(fingerprint),
      'createdAt': serializer.toJson<DateTime>(createdAt),
    };
  }

  SshKey copyWith({
    int? id,
    String? name,
    String? keyType,
    String? publicKey,
    String? privateKey,
    Value<String?> passphrase = const Value.absent(),
    Value<String?> fingerprint = const Value.absent(),
    DateTime? createdAt,
  }) => SshKey(
    id: id ?? this.id,
    name: name ?? this.name,
    keyType: keyType ?? this.keyType,
    publicKey: publicKey ?? this.publicKey,
    privateKey: privateKey ?? this.privateKey,
    passphrase: passphrase.present ? passphrase.value : this.passphrase,
    fingerprint: fingerprint.present ? fingerprint.value : this.fingerprint,
    createdAt: createdAt ?? this.createdAt,
  );
  SshKey copyWithCompanion(SshKeysCompanion data) {
    return SshKey(
      id: data.id.present ? data.id.value : this.id,
      name: data.name.present ? data.name.value : this.name,
      keyType: data.keyType.present ? data.keyType.value : this.keyType,
      publicKey: data.publicKey.present ? data.publicKey.value : this.publicKey,
      privateKey: data.privateKey.present
          ? data.privateKey.value
          : this.privateKey,
      passphrase: data.passphrase.present
          ? data.passphrase.value
          : this.passphrase,
      fingerprint: data.fingerprint.present
          ? data.fingerprint.value
          : this.fingerprint,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SshKey(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('keyType: $keyType, ')
          ..write('publicKey: $publicKey, ')
          ..write('privateKey: $privateKey, ')
          ..write('passphrase: $passphrase, ')
          ..write('fingerprint: $fingerprint, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    name,
    keyType,
    publicKey,
    privateKey,
    passphrase,
    fingerprint,
    createdAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SshKey &&
          other.id == this.id &&
          other.name == this.name &&
          other.keyType == this.keyType &&
          other.publicKey == this.publicKey &&
          other.privateKey == this.privateKey &&
          other.passphrase == this.passphrase &&
          other.fingerprint == this.fingerprint &&
          other.createdAt == this.createdAt);
}

class SshKeysCompanion extends UpdateCompanion<SshKey> {
  final Value<int> id;
  final Value<String> name;
  final Value<String> keyType;
  final Value<String> publicKey;
  final Value<String> privateKey;
  final Value<String?> passphrase;
  final Value<String?> fingerprint;
  final Value<DateTime> createdAt;
  const SshKeysCompanion({
    this.id = const Value.absent(),
    this.name = const Value.absent(),
    this.keyType = const Value.absent(),
    this.publicKey = const Value.absent(),
    this.privateKey = const Value.absent(),
    this.passphrase = const Value.absent(),
    this.fingerprint = const Value.absent(),
    this.createdAt = const Value.absent(),
  });
  SshKeysCompanion.insert({
    this.id = const Value.absent(),
    required String name,
    required String keyType,
    required String publicKey,
    required String privateKey,
    this.passphrase = const Value.absent(),
    this.fingerprint = const Value.absent(),
    this.createdAt = const Value.absent(),
  }) : name = Value(name),
       keyType = Value(keyType),
       publicKey = Value(publicKey),
       privateKey = Value(privateKey);
  static Insertable<SshKey> custom({
    Expression<int>? id,
    Expression<String>? name,
    Expression<String>? keyType,
    Expression<String>? publicKey,
    Expression<String>? privateKey,
    Expression<String>? passphrase,
    Expression<String>? fingerprint,
    Expression<DateTime>? createdAt,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (name != null) 'name': name,
      if (keyType != null) 'key_type': keyType,
      if (publicKey != null) 'public_key': publicKey,
      if (privateKey != null) 'private_key': privateKey,
      if (passphrase != null) 'passphrase': passphrase,
      if (fingerprint != null) 'fingerprint': fingerprint,
      if (createdAt != null) 'created_at': createdAt,
    });
  }

  SshKeysCompanion copyWith({
    Value<int>? id,
    Value<String>? name,
    Value<String>? keyType,
    Value<String>? publicKey,
    Value<String>? privateKey,
    Value<String?>? passphrase,
    Value<String?>? fingerprint,
    Value<DateTime>? createdAt,
  }) {
    return SshKeysCompanion(
      id: id ?? this.id,
      name: name ?? this.name,
      keyType: keyType ?? this.keyType,
      publicKey: publicKey ?? this.publicKey,
      privateKey: privateKey ?? this.privateKey,
      passphrase: passphrase ?? this.passphrase,
      fingerprint: fingerprint ?? this.fingerprint,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (keyType.present) {
      map['key_type'] = Variable<String>(keyType.value);
    }
    if (publicKey.present) {
      map['public_key'] = Variable<String>(publicKey.value);
    }
    if (privateKey.present) {
      map['private_key'] = Variable<String>(privateKey.value);
    }
    if (passphrase.present) {
      map['passphrase'] = Variable<String>(passphrase.value);
    }
    if (fingerprint.present) {
      map['fingerprint'] = Variable<String>(fingerprint.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SshKeysCompanion(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('keyType: $keyType, ')
          ..write('publicKey: $publicKey, ')
          ..write('privateKey: $privateKey, ')
          ..write('passphrase: $passphrase, ')
          ..write('fingerprint: $fingerprint, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }
}

class $GroupsTable extends Groups with TableInfo<$GroupsTable, Group> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $GroupsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    additionalChecks: GeneratedColumn.checkTextLength(
      minTextLength: 1,
      maxTextLength: 255,
    ),
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _parentIdMeta = const VerificationMeta(
    'parentId',
  );
  @override
  late final GeneratedColumn<int> parentId = GeneratedColumn<int>(
    'parent_id',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES "groups" (id)',
    ),
  );
  static const VerificationMeta _sortOrderMeta = const VerificationMeta(
    'sortOrder',
  );
  @override
  late final GeneratedColumn<int> sortOrder = GeneratedColumn<int>(
    'sort_order',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _colorMeta = const VerificationMeta('color');
  @override
  late final GeneratedColumn<String> color = GeneratedColumn<String>(
    'color',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _iconMeta = const VerificationMeta('icon');
  @override
  late final GeneratedColumn<String> icon = GeneratedColumn<String>(
    'icon',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
    defaultValue: currentDateAndTime,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    name,
    parentId,
    sortOrder,
    color,
    icon,
    createdAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'groups';
  @override
  VerificationContext validateIntegrity(
    Insertable<Group> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('parent_id')) {
      context.handle(
        _parentIdMeta,
        parentId.isAcceptableOrUnknown(data['parent_id']!, _parentIdMeta),
      );
    }
    if (data.containsKey('sort_order')) {
      context.handle(
        _sortOrderMeta,
        sortOrder.isAcceptableOrUnknown(data['sort_order']!, _sortOrderMeta),
      );
    }
    if (data.containsKey('color')) {
      context.handle(
        _colorMeta,
        color.isAcceptableOrUnknown(data['color']!, _colorMeta),
      );
    }
    if (data.containsKey('icon')) {
      context.handle(
        _iconMeta,
        icon.isAcceptableOrUnknown(data['icon']!, _iconMeta),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  Group map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Group(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      parentId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}parent_id'],
      ),
      sortOrder: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}sort_order'],
      )!,
      color: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}color'],
      ),
      icon: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}icon'],
      ),
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}created_at'],
      )!,
    );
  }

  @override
  $GroupsTable createAlias(String alias) {
    return $GroupsTable(attachedDatabase, alias);
  }
}

class Group extends DataClass implements Insertable<Group> {
  /// Unique identifier.
  final int id;

  /// Group name.
  final String name;

  /// Parent group for nested folders.
  final int? parentId;

  /// Display order within parent.
  final int sortOrder;

  /// Custom color for the group (hex string).
  final String? color;

  /// Custom icon name.
  final String? icon;

  /// Creation timestamp.
  final DateTime createdAt;
  const Group({
    required this.id,
    required this.name,
    this.parentId,
    required this.sortOrder,
    this.color,
    this.icon,
    required this.createdAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['name'] = Variable<String>(name);
    if (!nullToAbsent || parentId != null) {
      map['parent_id'] = Variable<int>(parentId);
    }
    map['sort_order'] = Variable<int>(sortOrder);
    if (!nullToAbsent || color != null) {
      map['color'] = Variable<String>(color);
    }
    if (!nullToAbsent || icon != null) {
      map['icon'] = Variable<String>(icon);
    }
    map['created_at'] = Variable<DateTime>(createdAt);
    return map;
  }

  GroupsCompanion toCompanion(bool nullToAbsent) {
    return GroupsCompanion(
      id: Value(id),
      name: Value(name),
      parentId: parentId == null && nullToAbsent
          ? const Value.absent()
          : Value(parentId),
      sortOrder: Value(sortOrder),
      color: color == null && nullToAbsent
          ? const Value.absent()
          : Value(color),
      icon: icon == null && nullToAbsent ? const Value.absent() : Value(icon),
      createdAt: Value(createdAt),
    );
  }

  factory Group.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Group(
      id: serializer.fromJson<int>(json['id']),
      name: serializer.fromJson<String>(json['name']),
      parentId: serializer.fromJson<int?>(json['parentId']),
      sortOrder: serializer.fromJson<int>(json['sortOrder']),
      color: serializer.fromJson<String?>(json['color']),
      icon: serializer.fromJson<String?>(json['icon']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'name': serializer.toJson<String>(name),
      'parentId': serializer.toJson<int?>(parentId),
      'sortOrder': serializer.toJson<int>(sortOrder),
      'color': serializer.toJson<String?>(color),
      'icon': serializer.toJson<String?>(icon),
      'createdAt': serializer.toJson<DateTime>(createdAt),
    };
  }

  Group copyWith({
    int? id,
    String? name,
    Value<int?> parentId = const Value.absent(),
    int? sortOrder,
    Value<String?> color = const Value.absent(),
    Value<String?> icon = const Value.absent(),
    DateTime? createdAt,
  }) => Group(
    id: id ?? this.id,
    name: name ?? this.name,
    parentId: parentId.present ? parentId.value : this.parentId,
    sortOrder: sortOrder ?? this.sortOrder,
    color: color.present ? color.value : this.color,
    icon: icon.present ? icon.value : this.icon,
    createdAt: createdAt ?? this.createdAt,
  );
  Group copyWithCompanion(GroupsCompanion data) {
    return Group(
      id: data.id.present ? data.id.value : this.id,
      name: data.name.present ? data.name.value : this.name,
      parentId: data.parentId.present ? data.parentId.value : this.parentId,
      sortOrder: data.sortOrder.present ? data.sortOrder.value : this.sortOrder,
      color: data.color.present ? data.color.value : this.color,
      icon: data.icon.present ? data.icon.value : this.icon,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Group(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('parentId: $parentId, ')
          ..write('sortOrder: $sortOrder, ')
          ..write('color: $color, ')
          ..write('icon: $icon, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(id, name, parentId, sortOrder, color, icon, createdAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Group &&
          other.id == this.id &&
          other.name == this.name &&
          other.parentId == this.parentId &&
          other.sortOrder == this.sortOrder &&
          other.color == this.color &&
          other.icon == this.icon &&
          other.createdAt == this.createdAt);
}

class GroupsCompanion extends UpdateCompanion<Group> {
  final Value<int> id;
  final Value<String> name;
  final Value<int?> parentId;
  final Value<int> sortOrder;
  final Value<String?> color;
  final Value<String?> icon;
  final Value<DateTime> createdAt;
  const GroupsCompanion({
    this.id = const Value.absent(),
    this.name = const Value.absent(),
    this.parentId = const Value.absent(),
    this.sortOrder = const Value.absent(),
    this.color = const Value.absent(),
    this.icon = const Value.absent(),
    this.createdAt = const Value.absent(),
  });
  GroupsCompanion.insert({
    this.id = const Value.absent(),
    required String name,
    this.parentId = const Value.absent(),
    this.sortOrder = const Value.absent(),
    this.color = const Value.absent(),
    this.icon = const Value.absent(),
    this.createdAt = const Value.absent(),
  }) : name = Value(name);
  static Insertable<Group> custom({
    Expression<int>? id,
    Expression<String>? name,
    Expression<int>? parentId,
    Expression<int>? sortOrder,
    Expression<String>? color,
    Expression<String>? icon,
    Expression<DateTime>? createdAt,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (name != null) 'name': name,
      if (parentId != null) 'parent_id': parentId,
      if (sortOrder != null) 'sort_order': sortOrder,
      if (color != null) 'color': color,
      if (icon != null) 'icon': icon,
      if (createdAt != null) 'created_at': createdAt,
    });
  }

  GroupsCompanion copyWith({
    Value<int>? id,
    Value<String>? name,
    Value<int?>? parentId,
    Value<int>? sortOrder,
    Value<String?>? color,
    Value<String?>? icon,
    Value<DateTime>? createdAt,
  }) {
    return GroupsCompanion(
      id: id ?? this.id,
      name: name ?? this.name,
      parentId: parentId ?? this.parentId,
      sortOrder: sortOrder ?? this.sortOrder,
      color: color ?? this.color,
      icon: icon ?? this.icon,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (parentId.present) {
      map['parent_id'] = Variable<int>(parentId.value);
    }
    if (sortOrder.present) {
      map['sort_order'] = Variable<int>(sortOrder.value);
    }
    if (color.present) {
      map['color'] = Variable<String>(color.value);
    }
    if (icon.present) {
      map['icon'] = Variable<String>(icon.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('GroupsCompanion(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('parentId: $parentId, ')
          ..write('sortOrder: $sortOrder, ')
          ..write('color: $color, ')
          ..write('icon: $icon, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }
}

class $SnippetFoldersTable extends SnippetFolders
    with TableInfo<$SnippetFoldersTable, SnippetFolder> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SnippetFoldersTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    additionalChecks: GeneratedColumn.checkTextLength(
      minTextLength: 1,
      maxTextLength: 255,
    ),
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _parentIdMeta = const VerificationMeta(
    'parentId',
  );
  @override
  late final GeneratedColumn<int> parentId = GeneratedColumn<int>(
    'parent_id',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES snippet_folders (id)',
    ),
  );
  static const VerificationMeta _sortOrderMeta = const VerificationMeta(
    'sortOrder',
  );
  @override
  late final GeneratedColumn<int> sortOrder = GeneratedColumn<int>(
    'sort_order',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
    defaultValue: currentDateAndTime,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    name,
    parentId,
    sortOrder,
    createdAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'snippet_folders';
  @override
  VerificationContext validateIntegrity(
    Insertable<SnippetFolder> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('parent_id')) {
      context.handle(
        _parentIdMeta,
        parentId.isAcceptableOrUnknown(data['parent_id']!, _parentIdMeta),
      );
    }
    if (data.containsKey('sort_order')) {
      context.handle(
        _sortOrderMeta,
        sortOrder.isAcceptableOrUnknown(data['sort_order']!, _sortOrderMeta),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  SnippetFolder map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SnippetFolder(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      parentId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}parent_id'],
      ),
      sortOrder: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}sort_order'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}created_at'],
      )!,
    );
  }

  @override
  $SnippetFoldersTable createAlias(String alias) {
    return $SnippetFoldersTable(attachedDatabase, alias);
  }
}

class SnippetFolder extends DataClass implements Insertable<SnippetFolder> {
  /// Unique identifier.
  final int id;

  /// Folder name.
  final String name;

  /// Parent folder for nesting.
  final int? parentId;

  /// Display order.
  final int sortOrder;

  /// Creation timestamp.
  final DateTime createdAt;
  const SnippetFolder({
    required this.id,
    required this.name,
    this.parentId,
    required this.sortOrder,
    required this.createdAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['name'] = Variable<String>(name);
    if (!nullToAbsent || parentId != null) {
      map['parent_id'] = Variable<int>(parentId);
    }
    map['sort_order'] = Variable<int>(sortOrder);
    map['created_at'] = Variable<DateTime>(createdAt);
    return map;
  }

  SnippetFoldersCompanion toCompanion(bool nullToAbsent) {
    return SnippetFoldersCompanion(
      id: Value(id),
      name: Value(name),
      parentId: parentId == null && nullToAbsent
          ? const Value.absent()
          : Value(parentId),
      sortOrder: Value(sortOrder),
      createdAt: Value(createdAt),
    );
  }

  factory SnippetFolder.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SnippetFolder(
      id: serializer.fromJson<int>(json['id']),
      name: serializer.fromJson<String>(json['name']),
      parentId: serializer.fromJson<int?>(json['parentId']),
      sortOrder: serializer.fromJson<int>(json['sortOrder']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'name': serializer.toJson<String>(name),
      'parentId': serializer.toJson<int?>(parentId),
      'sortOrder': serializer.toJson<int>(sortOrder),
      'createdAt': serializer.toJson<DateTime>(createdAt),
    };
  }

  SnippetFolder copyWith({
    int? id,
    String? name,
    Value<int?> parentId = const Value.absent(),
    int? sortOrder,
    DateTime? createdAt,
  }) => SnippetFolder(
    id: id ?? this.id,
    name: name ?? this.name,
    parentId: parentId.present ? parentId.value : this.parentId,
    sortOrder: sortOrder ?? this.sortOrder,
    createdAt: createdAt ?? this.createdAt,
  );
  SnippetFolder copyWithCompanion(SnippetFoldersCompanion data) {
    return SnippetFolder(
      id: data.id.present ? data.id.value : this.id,
      name: data.name.present ? data.name.value : this.name,
      parentId: data.parentId.present ? data.parentId.value : this.parentId,
      sortOrder: data.sortOrder.present ? data.sortOrder.value : this.sortOrder,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SnippetFolder(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('parentId: $parentId, ')
          ..write('sortOrder: $sortOrder, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, name, parentId, sortOrder, createdAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SnippetFolder &&
          other.id == this.id &&
          other.name == this.name &&
          other.parentId == this.parentId &&
          other.sortOrder == this.sortOrder &&
          other.createdAt == this.createdAt);
}

class SnippetFoldersCompanion extends UpdateCompanion<SnippetFolder> {
  final Value<int> id;
  final Value<String> name;
  final Value<int?> parentId;
  final Value<int> sortOrder;
  final Value<DateTime> createdAt;
  const SnippetFoldersCompanion({
    this.id = const Value.absent(),
    this.name = const Value.absent(),
    this.parentId = const Value.absent(),
    this.sortOrder = const Value.absent(),
    this.createdAt = const Value.absent(),
  });
  SnippetFoldersCompanion.insert({
    this.id = const Value.absent(),
    required String name,
    this.parentId = const Value.absent(),
    this.sortOrder = const Value.absent(),
    this.createdAt = const Value.absent(),
  }) : name = Value(name);
  static Insertable<SnippetFolder> custom({
    Expression<int>? id,
    Expression<String>? name,
    Expression<int>? parentId,
    Expression<int>? sortOrder,
    Expression<DateTime>? createdAt,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (name != null) 'name': name,
      if (parentId != null) 'parent_id': parentId,
      if (sortOrder != null) 'sort_order': sortOrder,
      if (createdAt != null) 'created_at': createdAt,
    });
  }

  SnippetFoldersCompanion copyWith({
    Value<int>? id,
    Value<String>? name,
    Value<int?>? parentId,
    Value<int>? sortOrder,
    Value<DateTime>? createdAt,
  }) {
    return SnippetFoldersCompanion(
      id: id ?? this.id,
      name: name ?? this.name,
      parentId: parentId ?? this.parentId,
      sortOrder: sortOrder ?? this.sortOrder,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (parentId.present) {
      map['parent_id'] = Variable<int>(parentId.value);
    }
    if (sortOrder.present) {
      map['sort_order'] = Variable<int>(sortOrder.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SnippetFoldersCompanion(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('parentId: $parentId, ')
          ..write('sortOrder: $sortOrder, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }
}

class $SnippetsTable extends Snippets with TableInfo<$SnippetsTable, Snippet> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SnippetsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    additionalChecks: GeneratedColumn.checkTextLength(
      minTextLength: 1,
      maxTextLength: 255,
    ),
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _commandMeta = const VerificationMeta(
    'command',
  );
  @override
  late final GeneratedColumn<String> command = GeneratedColumn<String>(
    'command',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _descriptionMeta = const VerificationMeta(
    'description',
  );
  @override
  late final GeneratedColumn<String> description = GeneratedColumn<String>(
    'description',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _folderIdMeta = const VerificationMeta(
    'folderId',
  );
  @override
  late final GeneratedColumn<int> folderId = GeneratedColumn<int>(
    'folder_id',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES snippet_folders (id)',
    ),
  );
  static const VerificationMeta _autoExecuteMeta = const VerificationMeta(
    'autoExecute',
  );
  @override
  late final GeneratedColumn<bool> autoExecute = GeneratedColumn<bool>(
    'auto_execute',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("auto_execute" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
    defaultValue: currentDateAndTime,
  );
  static const VerificationMeta _lastUsedAtMeta = const VerificationMeta(
    'lastUsedAt',
  );
  @override
  late final GeneratedColumn<DateTime> lastUsedAt = GeneratedColumn<DateTime>(
    'last_used_at',
    aliasedName,
    true,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _usageCountMeta = const VerificationMeta(
    'usageCount',
  );
  @override
  late final GeneratedColumn<int> usageCount = GeneratedColumn<int>(
    'usage_count',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _sortOrderMeta = const VerificationMeta(
    'sortOrder',
  );
  @override
  late final GeneratedColumn<int> sortOrder = GeneratedColumn<int>(
    'sort_order',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    name,
    command,
    description,
    folderId,
    autoExecute,
    createdAt,
    lastUsedAt,
    usageCount,
    sortOrder,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'snippets';
  @override
  VerificationContext validateIntegrity(
    Insertable<Snippet> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('command')) {
      context.handle(
        _commandMeta,
        command.isAcceptableOrUnknown(data['command']!, _commandMeta),
      );
    } else if (isInserting) {
      context.missing(_commandMeta);
    }
    if (data.containsKey('description')) {
      context.handle(
        _descriptionMeta,
        description.isAcceptableOrUnknown(
          data['description']!,
          _descriptionMeta,
        ),
      );
    }
    if (data.containsKey('folder_id')) {
      context.handle(
        _folderIdMeta,
        folderId.isAcceptableOrUnknown(data['folder_id']!, _folderIdMeta),
      );
    }
    if (data.containsKey('auto_execute')) {
      context.handle(
        _autoExecuteMeta,
        autoExecute.isAcceptableOrUnknown(
          data['auto_execute']!,
          _autoExecuteMeta,
        ),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    }
    if (data.containsKey('last_used_at')) {
      context.handle(
        _lastUsedAtMeta,
        lastUsedAt.isAcceptableOrUnknown(
          data['last_used_at']!,
          _lastUsedAtMeta,
        ),
      );
    }
    if (data.containsKey('usage_count')) {
      context.handle(
        _usageCountMeta,
        usageCount.isAcceptableOrUnknown(data['usage_count']!, _usageCountMeta),
      );
    }
    if (data.containsKey('sort_order')) {
      context.handle(
        _sortOrderMeta,
        sortOrder.isAcceptableOrUnknown(data['sort_order']!, _sortOrderMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  Snippet map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Snippet(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      command: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}command'],
      )!,
      description: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}description'],
      ),
      folderId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}folder_id'],
      ),
      autoExecute: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}auto_execute'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}created_at'],
      )!,
      lastUsedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}last_used_at'],
      ),
      usageCount: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}usage_count'],
      )!,
      sortOrder: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}sort_order'],
      )!,
    );
  }

  @override
  $SnippetsTable createAlias(String alias) {
    return $SnippetsTable(attachedDatabase, alias);
  }
}

class Snippet extends DataClass implements Insertable<Snippet> {
  /// Unique identifier.
  final int id;

  /// Snippet name.
  final String name;

  /// The command content.
  final String command;

  /// Optional description.
  final String? description;

  /// Reference to parent folder.
  final int? folderId;

  /// Whether to auto-execute on selection.
  final bool autoExecute;

  /// Creation timestamp.
  final DateTime createdAt;

  /// Last used timestamp.
  final DateTime? lastUsedAt;

  /// Usage count for sorting by frequency.
  final int usageCount;

  /// Display order within the snippets list.
  final int sortOrder;
  const Snippet({
    required this.id,
    required this.name,
    required this.command,
    this.description,
    this.folderId,
    required this.autoExecute,
    required this.createdAt,
    this.lastUsedAt,
    required this.usageCount,
    required this.sortOrder,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['name'] = Variable<String>(name);
    map['command'] = Variable<String>(command);
    if (!nullToAbsent || description != null) {
      map['description'] = Variable<String>(description);
    }
    if (!nullToAbsent || folderId != null) {
      map['folder_id'] = Variable<int>(folderId);
    }
    map['auto_execute'] = Variable<bool>(autoExecute);
    map['created_at'] = Variable<DateTime>(createdAt);
    if (!nullToAbsent || lastUsedAt != null) {
      map['last_used_at'] = Variable<DateTime>(lastUsedAt);
    }
    map['usage_count'] = Variable<int>(usageCount);
    map['sort_order'] = Variable<int>(sortOrder);
    return map;
  }

  SnippetsCompanion toCompanion(bool nullToAbsent) {
    return SnippetsCompanion(
      id: Value(id),
      name: Value(name),
      command: Value(command),
      description: description == null && nullToAbsent
          ? const Value.absent()
          : Value(description),
      folderId: folderId == null && nullToAbsent
          ? const Value.absent()
          : Value(folderId),
      autoExecute: Value(autoExecute),
      createdAt: Value(createdAt),
      lastUsedAt: lastUsedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(lastUsedAt),
      usageCount: Value(usageCount),
      sortOrder: Value(sortOrder),
    );
  }

  factory Snippet.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Snippet(
      id: serializer.fromJson<int>(json['id']),
      name: serializer.fromJson<String>(json['name']),
      command: serializer.fromJson<String>(json['command']),
      description: serializer.fromJson<String?>(json['description']),
      folderId: serializer.fromJson<int?>(json['folderId']),
      autoExecute: serializer.fromJson<bool>(json['autoExecute']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
      lastUsedAt: serializer.fromJson<DateTime?>(json['lastUsedAt']),
      usageCount: serializer.fromJson<int>(json['usageCount']),
      sortOrder: serializer.fromJson<int>(json['sortOrder']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'name': serializer.toJson<String>(name),
      'command': serializer.toJson<String>(command),
      'description': serializer.toJson<String?>(description),
      'folderId': serializer.toJson<int?>(folderId),
      'autoExecute': serializer.toJson<bool>(autoExecute),
      'createdAt': serializer.toJson<DateTime>(createdAt),
      'lastUsedAt': serializer.toJson<DateTime?>(lastUsedAt),
      'usageCount': serializer.toJson<int>(usageCount),
      'sortOrder': serializer.toJson<int>(sortOrder),
    };
  }

  Snippet copyWith({
    int? id,
    String? name,
    String? command,
    Value<String?> description = const Value.absent(),
    Value<int?> folderId = const Value.absent(),
    bool? autoExecute,
    DateTime? createdAt,
    Value<DateTime?> lastUsedAt = const Value.absent(),
    int? usageCount,
    int? sortOrder,
  }) => Snippet(
    id: id ?? this.id,
    name: name ?? this.name,
    command: command ?? this.command,
    description: description.present ? description.value : this.description,
    folderId: folderId.present ? folderId.value : this.folderId,
    autoExecute: autoExecute ?? this.autoExecute,
    createdAt: createdAt ?? this.createdAt,
    lastUsedAt: lastUsedAt.present ? lastUsedAt.value : this.lastUsedAt,
    usageCount: usageCount ?? this.usageCount,
    sortOrder: sortOrder ?? this.sortOrder,
  );
  Snippet copyWithCompanion(SnippetsCompanion data) {
    return Snippet(
      id: data.id.present ? data.id.value : this.id,
      name: data.name.present ? data.name.value : this.name,
      command: data.command.present ? data.command.value : this.command,
      description: data.description.present
          ? data.description.value
          : this.description,
      folderId: data.folderId.present ? data.folderId.value : this.folderId,
      autoExecute: data.autoExecute.present
          ? data.autoExecute.value
          : this.autoExecute,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      lastUsedAt: data.lastUsedAt.present
          ? data.lastUsedAt.value
          : this.lastUsedAt,
      usageCount: data.usageCount.present
          ? data.usageCount.value
          : this.usageCount,
      sortOrder: data.sortOrder.present ? data.sortOrder.value : this.sortOrder,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Snippet(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('command: $command, ')
          ..write('description: $description, ')
          ..write('folderId: $folderId, ')
          ..write('autoExecute: $autoExecute, ')
          ..write('createdAt: $createdAt, ')
          ..write('lastUsedAt: $lastUsedAt, ')
          ..write('usageCount: $usageCount, ')
          ..write('sortOrder: $sortOrder')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    name,
    command,
    description,
    folderId,
    autoExecute,
    createdAt,
    lastUsedAt,
    usageCount,
    sortOrder,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Snippet &&
          other.id == this.id &&
          other.name == this.name &&
          other.command == this.command &&
          other.description == this.description &&
          other.folderId == this.folderId &&
          other.autoExecute == this.autoExecute &&
          other.createdAt == this.createdAt &&
          other.lastUsedAt == this.lastUsedAt &&
          other.usageCount == this.usageCount &&
          other.sortOrder == this.sortOrder);
}

class SnippetsCompanion extends UpdateCompanion<Snippet> {
  final Value<int> id;
  final Value<String> name;
  final Value<String> command;
  final Value<String?> description;
  final Value<int?> folderId;
  final Value<bool> autoExecute;
  final Value<DateTime> createdAt;
  final Value<DateTime?> lastUsedAt;
  final Value<int> usageCount;
  final Value<int> sortOrder;
  const SnippetsCompanion({
    this.id = const Value.absent(),
    this.name = const Value.absent(),
    this.command = const Value.absent(),
    this.description = const Value.absent(),
    this.folderId = const Value.absent(),
    this.autoExecute = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.lastUsedAt = const Value.absent(),
    this.usageCount = const Value.absent(),
    this.sortOrder = const Value.absent(),
  });
  SnippetsCompanion.insert({
    this.id = const Value.absent(),
    required String name,
    required String command,
    this.description = const Value.absent(),
    this.folderId = const Value.absent(),
    this.autoExecute = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.lastUsedAt = const Value.absent(),
    this.usageCount = const Value.absent(),
    this.sortOrder = const Value.absent(),
  }) : name = Value(name),
       command = Value(command);
  static Insertable<Snippet> custom({
    Expression<int>? id,
    Expression<String>? name,
    Expression<String>? command,
    Expression<String>? description,
    Expression<int>? folderId,
    Expression<bool>? autoExecute,
    Expression<DateTime>? createdAt,
    Expression<DateTime>? lastUsedAt,
    Expression<int>? usageCount,
    Expression<int>? sortOrder,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (name != null) 'name': name,
      if (command != null) 'command': command,
      if (description != null) 'description': description,
      if (folderId != null) 'folder_id': folderId,
      if (autoExecute != null) 'auto_execute': autoExecute,
      if (createdAt != null) 'created_at': createdAt,
      if (lastUsedAt != null) 'last_used_at': lastUsedAt,
      if (usageCount != null) 'usage_count': usageCount,
      if (sortOrder != null) 'sort_order': sortOrder,
    });
  }

  SnippetsCompanion copyWith({
    Value<int>? id,
    Value<String>? name,
    Value<String>? command,
    Value<String?>? description,
    Value<int?>? folderId,
    Value<bool>? autoExecute,
    Value<DateTime>? createdAt,
    Value<DateTime?>? lastUsedAt,
    Value<int>? usageCount,
    Value<int>? sortOrder,
  }) {
    return SnippetsCompanion(
      id: id ?? this.id,
      name: name ?? this.name,
      command: command ?? this.command,
      description: description ?? this.description,
      folderId: folderId ?? this.folderId,
      autoExecute: autoExecute ?? this.autoExecute,
      createdAt: createdAt ?? this.createdAt,
      lastUsedAt: lastUsedAt ?? this.lastUsedAt,
      usageCount: usageCount ?? this.usageCount,
      sortOrder: sortOrder ?? this.sortOrder,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (command.present) {
      map['command'] = Variable<String>(command.value);
    }
    if (description.present) {
      map['description'] = Variable<String>(description.value);
    }
    if (folderId.present) {
      map['folder_id'] = Variable<int>(folderId.value);
    }
    if (autoExecute.present) {
      map['auto_execute'] = Variable<bool>(autoExecute.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (lastUsedAt.present) {
      map['last_used_at'] = Variable<DateTime>(lastUsedAt.value);
    }
    if (usageCount.present) {
      map['usage_count'] = Variable<int>(usageCount.value);
    }
    if (sortOrder.present) {
      map['sort_order'] = Variable<int>(sortOrder.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SnippetsCompanion(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('command: $command, ')
          ..write('description: $description, ')
          ..write('folderId: $folderId, ')
          ..write('autoExecute: $autoExecute, ')
          ..write('createdAt: $createdAt, ')
          ..write('lastUsedAt: $lastUsedAt, ')
          ..write('usageCount: $usageCount, ')
          ..write('sortOrder: $sortOrder')
          ..write(')'))
        .toString();
  }
}

class $HostsTable extends Hosts with TableInfo<$HostsTable, Host> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $HostsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _labelMeta = const VerificationMeta('label');
  @override
  late final GeneratedColumn<String> label = GeneratedColumn<String>(
    'label',
    aliasedName,
    false,
    additionalChecks: GeneratedColumn.checkTextLength(
      minTextLength: 1,
      maxTextLength: 255,
    ),
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _hostnameMeta = const VerificationMeta(
    'hostname',
  );
  @override
  late final GeneratedColumn<String> hostname = GeneratedColumn<String>(
    'hostname',
    aliasedName,
    false,
    additionalChecks: GeneratedColumn.checkTextLength(
      minTextLength: 1,
      maxTextLength: 255,
    ),
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _portMeta = const VerificationMeta('port');
  @override
  late final GeneratedColumn<int> port = GeneratedColumn<int>(
    'port',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(22),
  );
  static const VerificationMeta _usernameMeta = const VerificationMeta(
    'username',
  );
  @override
  late final GeneratedColumn<String> username = GeneratedColumn<String>(
    'username',
    aliasedName,
    false,
    additionalChecks: GeneratedColumn.checkTextLength(
      minTextLength: 1,
      maxTextLength: 255,
    ),
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _passwordMeta = const VerificationMeta(
    'password',
  );
  @override
  late final GeneratedColumn<String> password = GeneratedColumn<String>(
    'password',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _keyIdMeta = const VerificationMeta('keyId');
  @override
  late final GeneratedColumn<int> keyId = GeneratedColumn<int>(
    'key_id',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES ssh_keys (id)',
    ),
  );
  static const VerificationMeta _groupIdMeta = const VerificationMeta(
    'groupId',
  );
  @override
  late final GeneratedColumn<int> groupId = GeneratedColumn<int>(
    'group_id',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES "groups" (id)',
    ),
  );
  static const VerificationMeta _jumpHostIdMeta = const VerificationMeta(
    'jumpHostId',
  );
  @override
  late final GeneratedColumn<int> jumpHostId = GeneratedColumn<int>(
    'jump_host_id',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES hosts (id)',
    ),
  );
  static const VerificationMeta _skipJumpHostOnSsidsMeta =
      const VerificationMeta('skipJumpHostOnSsids');
  @override
  late final GeneratedColumn<String> skipJumpHostOnSsids =
      GeneratedColumn<String>(
        'skip_jump_host_on_ssids',
        aliasedName,
        true,
        type: DriftSqlType.string,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _isFavoriteMeta = const VerificationMeta(
    'isFavorite',
  );
  @override
  late final GeneratedColumn<bool> isFavorite = GeneratedColumn<bool>(
    'is_favorite',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("is_favorite" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _colorMeta = const VerificationMeta('color');
  @override
  late final GeneratedColumn<String> color = GeneratedColumn<String>(
    'color',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _notesMeta = const VerificationMeta('notes');
  @override
  late final GeneratedColumn<String> notes = GeneratedColumn<String>(
    'notes',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _tagsMeta = const VerificationMeta('tags');
  @override
  late final GeneratedColumn<String> tags = GeneratedColumn<String>(
    'tags',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
    defaultValue: currentDateAndTime,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
    defaultValue: currentDateAndTime,
  );
  static const VerificationMeta _lastConnectedAtMeta = const VerificationMeta(
    'lastConnectedAt',
  );
  @override
  late final GeneratedColumn<DateTime> lastConnectedAt =
      GeneratedColumn<DateTime>(
        'last_connected_at',
        aliasedName,
        true,
        type: DriftSqlType.dateTime,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _terminalThemeLightIdMeta =
      const VerificationMeta('terminalThemeLightId');
  @override
  late final GeneratedColumn<String> terminalThemeLightId =
      GeneratedColumn<String>(
        'terminal_theme_light_id',
        aliasedName,
        true,
        type: DriftSqlType.string,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _terminalThemeDarkIdMeta =
      const VerificationMeta('terminalThemeDarkId');
  @override
  late final GeneratedColumn<String> terminalThemeDarkId =
      GeneratedColumn<String>(
        'terminal_theme_dark_id',
        aliasedName,
        true,
        type: DriftSqlType.string,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _terminalFontFamilyMeta =
      const VerificationMeta('terminalFontFamily');
  @override
  late final GeneratedColumn<String> terminalFontFamily =
      GeneratedColumn<String>(
        'terminal_font_family',
        aliasedName,
        true,
        type: DriftSqlType.string,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _autoConnectCommandMeta =
      const VerificationMeta('autoConnectCommand');
  @override
  late final GeneratedColumn<String> autoConnectCommand =
      GeneratedColumn<String>(
        'auto_connect_command',
        aliasedName,
        true,
        type: DriftSqlType.string,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _autoConnectSnippetIdMeta =
      const VerificationMeta('autoConnectSnippetId');
  @override
  late final GeneratedColumn<int> autoConnectSnippetId = GeneratedColumn<int>(
    'auto_connect_snippet_id',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES snippets (id)',
    ),
  );
  static const VerificationMeta _autoConnectRequiresConfirmationMeta =
      const VerificationMeta('autoConnectRequiresConfirmation');
  @override
  late final GeneratedColumn<bool> autoConnectRequiresConfirmation =
      GeneratedColumn<bool>(
        'auto_connect_requires_confirmation',
        aliasedName,
        false,
        type: DriftSqlType.bool,
        requiredDuringInsert: false,
        defaultConstraints: GeneratedColumn.constraintIsAlways(
          'CHECK ("auto_connect_requires_confirmation" IN (0, 1))',
        ),
        defaultValue: const Constant(false),
      );
  static const VerificationMeta _tmuxSessionNameMeta = const VerificationMeta(
    'tmuxSessionName',
  );
  @override
  late final GeneratedColumn<String> tmuxSessionName = GeneratedColumn<String>(
    'tmux_session_name',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _tmuxWorkingDirectoryMeta =
      const VerificationMeta('tmuxWorkingDirectory');
  @override
  late final GeneratedColumn<String> tmuxWorkingDirectory =
      GeneratedColumn<String>(
        'tmux_working_directory',
        aliasedName,
        true,
        type: DriftSqlType.string,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _tmuxExtraFlagsMeta = const VerificationMeta(
    'tmuxExtraFlags',
  );
  @override
  late final GeneratedColumn<String> tmuxExtraFlags = GeneratedColumn<String>(
    'tmux_extra_flags',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _remoteMuxBackendMeta = const VerificationMeta(
    'remoteMuxBackend',
  );
  @override
  late final GeneratedColumn<String> remoteMuxBackend = GeneratedColumn<String>(
    'remote_mux_backend',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _autoForwardPortsMeta = const VerificationMeta(
    'autoForwardPorts',
  );
  @override
  late final GeneratedColumn<bool> autoForwardPorts = GeneratedColumn<bool>(
    'auto_forward_ports',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("auto_forward_ports" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _portProxyNameMeta = const VerificationMeta(
    'portProxyName',
  );
  @override
  late final GeneratedColumn<String> portProxyName = GeneratedColumn<String>(
    'port_proxy_name',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _sortOrderMeta = const VerificationMeta(
    'sortOrder',
  );
  @override
  late final GeneratedColumn<int> sortOrder = GeneratedColumn<int>(
    'sort_order',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    label,
    hostname,
    port,
    username,
    password,
    keyId,
    groupId,
    jumpHostId,
    skipJumpHostOnSsids,
    isFavorite,
    color,
    notes,
    tags,
    createdAt,
    updatedAt,
    lastConnectedAt,
    terminalThemeLightId,
    terminalThemeDarkId,
    terminalFontFamily,
    autoConnectCommand,
    autoConnectSnippetId,
    autoConnectRequiresConfirmation,
    tmuxSessionName,
    tmuxWorkingDirectory,
    tmuxExtraFlags,
    remoteMuxBackend,
    autoForwardPorts,
    portProxyName,
    sortOrder,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'hosts';
  @override
  VerificationContext validateIntegrity(
    Insertable<Host> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('label')) {
      context.handle(
        _labelMeta,
        label.isAcceptableOrUnknown(data['label']!, _labelMeta),
      );
    } else if (isInserting) {
      context.missing(_labelMeta);
    }
    if (data.containsKey('hostname')) {
      context.handle(
        _hostnameMeta,
        hostname.isAcceptableOrUnknown(data['hostname']!, _hostnameMeta),
      );
    } else if (isInserting) {
      context.missing(_hostnameMeta);
    }
    if (data.containsKey('port')) {
      context.handle(
        _portMeta,
        port.isAcceptableOrUnknown(data['port']!, _portMeta),
      );
    }
    if (data.containsKey('username')) {
      context.handle(
        _usernameMeta,
        username.isAcceptableOrUnknown(data['username']!, _usernameMeta),
      );
    } else if (isInserting) {
      context.missing(_usernameMeta);
    }
    if (data.containsKey('password')) {
      context.handle(
        _passwordMeta,
        password.isAcceptableOrUnknown(data['password']!, _passwordMeta),
      );
    }
    if (data.containsKey('key_id')) {
      context.handle(
        _keyIdMeta,
        keyId.isAcceptableOrUnknown(data['key_id']!, _keyIdMeta),
      );
    }
    if (data.containsKey('group_id')) {
      context.handle(
        _groupIdMeta,
        groupId.isAcceptableOrUnknown(data['group_id']!, _groupIdMeta),
      );
    }
    if (data.containsKey('jump_host_id')) {
      context.handle(
        _jumpHostIdMeta,
        jumpHostId.isAcceptableOrUnknown(
          data['jump_host_id']!,
          _jumpHostIdMeta,
        ),
      );
    }
    if (data.containsKey('skip_jump_host_on_ssids')) {
      context.handle(
        _skipJumpHostOnSsidsMeta,
        skipJumpHostOnSsids.isAcceptableOrUnknown(
          data['skip_jump_host_on_ssids']!,
          _skipJumpHostOnSsidsMeta,
        ),
      );
    }
    if (data.containsKey('is_favorite')) {
      context.handle(
        _isFavoriteMeta,
        isFavorite.isAcceptableOrUnknown(data['is_favorite']!, _isFavoriteMeta),
      );
    }
    if (data.containsKey('color')) {
      context.handle(
        _colorMeta,
        color.isAcceptableOrUnknown(data['color']!, _colorMeta),
      );
    }
    if (data.containsKey('notes')) {
      context.handle(
        _notesMeta,
        notes.isAcceptableOrUnknown(data['notes']!, _notesMeta),
      );
    }
    if (data.containsKey('tags')) {
      context.handle(
        _tagsMeta,
        tags.isAcceptableOrUnknown(data['tags']!, _tagsMeta),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    }
    if (data.containsKey('last_connected_at')) {
      context.handle(
        _lastConnectedAtMeta,
        lastConnectedAt.isAcceptableOrUnknown(
          data['last_connected_at']!,
          _lastConnectedAtMeta,
        ),
      );
    }
    if (data.containsKey('terminal_theme_light_id')) {
      context.handle(
        _terminalThemeLightIdMeta,
        terminalThemeLightId.isAcceptableOrUnknown(
          data['terminal_theme_light_id']!,
          _terminalThemeLightIdMeta,
        ),
      );
    }
    if (data.containsKey('terminal_theme_dark_id')) {
      context.handle(
        _terminalThemeDarkIdMeta,
        terminalThemeDarkId.isAcceptableOrUnknown(
          data['terminal_theme_dark_id']!,
          _terminalThemeDarkIdMeta,
        ),
      );
    }
    if (data.containsKey('terminal_font_family')) {
      context.handle(
        _terminalFontFamilyMeta,
        terminalFontFamily.isAcceptableOrUnknown(
          data['terminal_font_family']!,
          _terminalFontFamilyMeta,
        ),
      );
    }
    if (data.containsKey('auto_connect_command')) {
      context.handle(
        _autoConnectCommandMeta,
        autoConnectCommand.isAcceptableOrUnknown(
          data['auto_connect_command']!,
          _autoConnectCommandMeta,
        ),
      );
    }
    if (data.containsKey('auto_connect_snippet_id')) {
      context.handle(
        _autoConnectSnippetIdMeta,
        autoConnectSnippetId.isAcceptableOrUnknown(
          data['auto_connect_snippet_id']!,
          _autoConnectSnippetIdMeta,
        ),
      );
    }
    if (data.containsKey('auto_connect_requires_confirmation')) {
      context.handle(
        _autoConnectRequiresConfirmationMeta,
        autoConnectRequiresConfirmation.isAcceptableOrUnknown(
          data['auto_connect_requires_confirmation']!,
          _autoConnectRequiresConfirmationMeta,
        ),
      );
    }
    if (data.containsKey('tmux_session_name')) {
      context.handle(
        _tmuxSessionNameMeta,
        tmuxSessionName.isAcceptableOrUnknown(
          data['tmux_session_name']!,
          _tmuxSessionNameMeta,
        ),
      );
    }
    if (data.containsKey('tmux_working_directory')) {
      context.handle(
        _tmuxWorkingDirectoryMeta,
        tmuxWorkingDirectory.isAcceptableOrUnknown(
          data['tmux_working_directory']!,
          _tmuxWorkingDirectoryMeta,
        ),
      );
    }
    if (data.containsKey('tmux_extra_flags')) {
      context.handle(
        _tmuxExtraFlagsMeta,
        tmuxExtraFlags.isAcceptableOrUnknown(
          data['tmux_extra_flags']!,
          _tmuxExtraFlagsMeta,
        ),
      );
    }
    if (data.containsKey('remote_mux_backend')) {
      context.handle(
        _remoteMuxBackendMeta,
        remoteMuxBackend.isAcceptableOrUnknown(
          data['remote_mux_backend']!,
          _remoteMuxBackendMeta,
        ),
      );
    }
    if (data.containsKey('auto_forward_ports')) {
      context.handle(
        _autoForwardPortsMeta,
        autoForwardPorts.isAcceptableOrUnknown(
          data['auto_forward_ports']!,
          _autoForwardPortsMeta,
        ),
      );
    }
    if (data.containsKey('port_proxy_name')) {
      context.handle(
        _portProxyNameMeta,
        portProxyName.isAcceptableOrUnknown(
          data['port_proxy_name']!,
          _portProxyNameMeta,
        ),
      );
    }
    if (data.containsKey('sort_order')) {
      context.handle(
        _sortOrderMeta,
        sortOrder.isAcceptableOrUnknown(data['sort_order']!, _sortOrderMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  Host map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Host(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      label: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}label'],
      )!,
      hostname: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}hostname'],
      )!,
      port: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}port'],
      )!,
      username: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}username'],
      )!,
      password: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}password'],
      ),
      keyId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}key_id'],
      ),
      groupId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}group_id'],
      ),
      jumpHostId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}jump_host_id'],
      ),
      skipJumpHostOnSsids: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}skip_jump_host_on_ssids'],
      ),
      isFavorite: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}is_favorite'],
      )!,
      color: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}color'],
      ),
      notes: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}notes'],
      ),
      tags: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}tags'],
      ),
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}created_at'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}updated_at'],
      )!,
      lastConnectedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}last_connected_at'],
      ),
      terminalThemeLightId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}terminal_theme_light_id'],
      ),
      terminalThemeDarkId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}terminal_theme_dark_id'],
      ),
      terminalFontFamily: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}terminal_font_family'],
      ),
      autoConnectCommand: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}auto_connect_command'],
      ),
      autoConnectSnippetId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}auto_connect_snippet_id'],
      ),
      autoConnectRequiresConfirmation: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}auto_connect_requires_confirmation'],
      )!,
      tmuxSessionName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}tmux_session_name'],
      ),
      tmuxWorkingDirectory: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}tmux_working_directory'],
      ),
      tmuxExtraFlags: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}tmux_extra_flags'],
      ),
      remoteMuxBackend: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}remote_mux_backend'],
      ),
      autoForwardPorts: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}auto_forward_ports'],
      )!,
      portProxyName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}port_proxy_name'],
      ),
      sortOrder: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}sort_order'],
      )!,
    );
  }

  @override
  $HostsTable createAlias(String alias) {
    return $HostsTable(attachedDatabase, alias);
  }
}

class Host extends DataClass implements Insertable<Host> {
  /// Unique identifier.
  final int id;

  /// Display label for the host.
  final String label;

  /// Hostname or IP address.
  final String hostname;

  /// SSH port (default 22).
  final int port;

  /// Username for authentication.
  final String username;

  /// Optional password (stored encrypted).
  final String? password;

  /// Reference to SSH key for authentication.
  final int? keyId;

  /// Reference to parent group.
  final int? groupId;

  /// Reference to jump host for proxy connections.
  final int? jumpHostId;

  /// Newline-separated list of Wi-Fi SSIDs on which the configured jump host
  /// should be skipped (the host is reached directly when the device is on
  /// one of these networks).
  final String? skipJumpHostOnSsids;

  /// Whether this host is marked as favorite.
  final bool isFavorite;

  /// Custom color for the host (hex string).
  final String? color;

  /// Additional notes.
  final String? notes;

  /// Comma-separated tags.
  final String? tags;

  /// Creation timestamp.
  final DateTime createdAt;

  /// Last modified timestamp.
  final DateTime updatedAt;

  /// Last connection timestamp.
  final DateTime? lastConnectedAt;

  /// Terminal theme ID for light mode (null = use global default).
  final String? terminalThemeLightId;

  /// Terminal theme ID for dark mode (null = use global default).
  final String? terminalThemeDarkId;

  /// Terminal font family (null = use global default).
  final String? terminalFontFamily;

  /// Cached command to run automatically after connecting/reconnecting.
  final String? autoConnectCommand;

  /// Referenced snippet to run automatically after connecting/reconnecting.
  final int? autoConnectSnippetId;

  /// Whether auto-connect should require user review before it can run.
  final bool autoConnectRequiresConfirmation;

  /// tmux session name to attach/create on connect.
  ///
  /// When set, the app generates a `tmux new-session -A -s <name>` command
  /// instead of using [autoConnectCommand], and knows the session name
  /// directly for window navigation.
  final String? tmuxSessionName;

  /// Working directory to use when starting a tmux session.
  ///
  /// Passed as `-c <dir>` to `tmux new-session`.
  final String? tmuxWorkingDirectory;

  /// Extra tmux flags appended to the generated `tmux new-session` command.
  final String? tmuxExtraFlags;

  /// Remote multiplexer backend used with [tmuxSessionName].
  ///
  /// Null preserves legacy behavior and means tmux when [tmuxSessionName] is
  /// populated.
  final String? remoteMuxBackend;

  /// Whether newly opened remote TCP ports should be forwarded automatically.
  final bool autoForwardPorts;

  /// Optional user-defined prefix for this host's `.localhost` proxy domain.
  final String? portProxyName;

  /// Display order within the hosts list.
  final int sortOrder;
  const Host({
    required this.id,
    required this.label,
    required this.hostname,
    required this.port,
    required this.username,
    this.password,
    this.keyId,
    this.groupId,
    this.jumpHostId,
    this.skipJumpHostOnSsids,
    required this.isFavorite,
    this.color,
    this.notes,
    this.tags,
    required this.createdAt,
    required this.updatedAt,
    this.lastConnectedAt,
    this.terminalThemeLightId,
    this.terminalThemeDarkId,
    this.terminalFontFamily,
    this.autoConnectCommand,
    this.autoConnectSnippetId,
    required this.autoConnectRequiresConfirmation,
    this.tmuxSessionName,
    this.tmuxWorkingDirectory,
    this.tmuxExtraFlags,
    this.remoteMuxBackend,
    required this.autoForwardPorts,
    this.portProxyName,
    required this.sortOrder,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['label'] = Variable<String>(label);
    map['hostname'] = Variable<String>(hostname);
    map['port'] = Variable<int>(port);
    map['username'] = Variable<String>(username);
    if (!nullToAbsent || password != null) {
      map['password'] = Variable<String>(password);
    }
    if (!nullToAbsent || keyId != null) {
      map['key_id'] = Variable<int>(keyId);
    }
    if (!nullToAbsent || groupId != null) {
      map['group_id'] = Variable<int>(groupId);
    }
    if (!nullToAbsent || jumpHostId != null) {
      map['jump_host_id'] = Variable<int>(jumpHostId);
    }
    if (!nullToAbsent || skipJumpHostOnSsids != null) {
      map['skip_jump_host_on_ssids'] = Variable<String>(skipJumpHostOnSsids);
    }
    map['is_favorite'] = Variable<bool>(isFavorite);
    if (!nullToAbsent || color != null) {
      map['color'] = Variable<String>(color);
    }
    if (!nullToAbsent || notes != null) {
      map['notes'] = Variable<String>(notes);
    }
    if (!nullToAbsent || tags != null) {
      map['tags'] = Variable<String>(tags);
    }
    map['created_at'] = Variable<DateTime>(createdAt);
    map['updated_at'] = Variable<DateTime>(updatedAt);
    if (!nullToAbsent || lastConnectedAt != null) {
      map['last_connected_at'] = Variable<DateTime>(lastConnectedAt);
    }
    if (!nullToAbsent || terminalThemeLightId != null) {
      map['terminal_theme_light_id'] = Variable<String>(terminalThemeLightId);
    }
    if (!nullToAbsent || terminalThemeDarkId != null) {
      map['terminal_theme_dark_id'] = Variable<String>(terminalThemeDarkId);
    }
    if (!nullToAbsent || terminalFontFamily != null) {
      map['terminal_font_family'] = Variable<String>(terminalFontFamily);
    }
    if (!nullToAbsent || autoConnectCommand != null) {
      map['auto_connect_command'] = Variable<String>(autoConnectCommand);
    }
    if (!nullToAbsent || autoConnectSnippetId != null) {
      map['auto_connect_snippet_id'] = Variable<int>(autoConnectSnippetId);
    }
    map['auto_connect_requires_confirmation'] = Variable<bool>(
      autoConnectRequiresConfirmation,
    );
    if (!nullToAbsent || tmuxSessionName != null) {
      map['tmux_session_name'] = Variable<String>(tmuxSessionName);
    }
    if (!nullToAbsent || tmuxWorkingDirectory != null) {
      map['tmux_working_directory'] = Variable<String>(tmuxWorkingDirectory);
    }
    if (!nullToAbsent || tmuxExtraFlags != null) {
      map['tmux_extra_flags'] = Variable<String>(tmuxExtraFlags);
    }
    if (!nullToAbsent || remoteMuxBackend != null) {
      map['remote_mux_backend'] = Variable<String>(remoteMuxBackend);
    }
    map['auto_forward_ports'] = Variable<bool>(autoForwardPorts);
    if (!nullToAbsent || portProxyName != null) {
      map['port_proxy_name'] = Variable<String>(portProxyName);
    }
    map['sort_order'] = Variable<int>(sortOrder);
    return map;
  }

  HostsCompanion toCompanion(bool nullToAbsent) {
    return HostsCompanion(
      id: Value(id),
      label: Value(label),
      hostname: Value(hostname),
      port: Value(port),
      username: Value(username),
      password: password == null && nullToAbsent
          ? const Value.absent()
          : Value(password),
      keyId: keyId == null && nullToAbsent
          ? const Value.absent()
          : Value(keyId),
      groupId: groupId == null && nullToAbsent
          ? const Value.absent()
          : Value(groupId),
      jumpHostId: jumpHostId == null && nullToAbsent
          ? const Value.absent()
          : Value(jumpHostId),
      skipJumpHostOnSsids: skipJumpHostOnSsids == null && nullToAbsent
          ? const Value.absent()
          : Value(skipJumpHostOnSsids),
      isFavorite: Value(isFavorite),
      color: color == null && nullToAbsent
          ? const Value.absent()
          : Value(color),
      notes: notes == null && nullToAbsent
          ? const Value.absent()
          : Value(notes),
      tags: tags == null && nullToAbsent ? const Value.absent() : Value(tags),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
      lastConnectedAt: lastConnectedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(lastConnectedAt),
      terminalThemeLightId: terminalThemeLightId == null && nullToAbsent
          ? const Value.absent()
          : Value(terminalThemeLightId),
      terminalThemeDarkId: terminalThemeDarkId == null && nullToAbsent
          ? const Value.absent()
          : Value(terminalThemeDarkId),
      terminalFontFamily: terminalFontFamily == null && nullToAbsent
          ? const Value.absent()
          : Value(terminalFontFamily),
      autoConnectCommand: autoConnectCommand == null && nullToAbsent
          ? const Value.absent()
          : Value(autoConnectCommand),
      autoConnectSnippetId: autoConnectSnippetId == null && nullToAbsent
          ? const Value.absent()
          : Value(autoConnectSnippetId),
      autoConnectRequiresConfirmation: Value(autoConnectRequiresConfirmation),
      tmuxSessionName: tmuxSessionName == null && nullToAbsent
          ? const Value.absent()
          : Value(tmuxSessionName),
      tmuxWorkingDirectory: tmuxWorkingDirectory == null && nullToAbsent
          ? const Value.absent()
          : Value(tmuxWorkingDirectory),
      tmuxExtraFlags: tmuxExtraFlags == null && nullToAbsent
          ? const Value.absent()
          : Value(tmuxExtraFlags),
      remoteMuxBackend: remoteMuxBackend == null && nullToAbsent
          ? const Value.absent()
          : Value(remoteMuxBackend),
      autoForwardPorts: Value(autoForwardPorts),
      portProxyName: portProxyName == null && nullToAbsent
          ? const Value.absent()
          : Value(portProxyName),
      sortOrder: Value(sortOrder),
    );
  }

  factory Host.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Host(
      id: serializer.fromJson<int>(json['id']),
      label: serializer.fromJson<String>(json['label']),
      hostname: serializer.fromJson<String>(json['hostname']),
      port: serializer.fromJson<int>(json['port']),
      username: serializer.fromJson<String>(json['username']),
      password: serializer.fromJson<String?>(json['password']),
      keyId: serializer.fromJson<int?>(json['keyId']),
      groupId: serializer.fromJson<int?>(json['groupId']),
      jumpHostId: serializer.fromJson<int?>(json['jumpHostId']),
      skipJumpHostOnSsids: serializer.fromJson<String?>(
        json['skipJumpHostOnSsids'],
      ),
      isFavorite: serializer.fromJson<bool>(json['isFavorite']),
      color: serializer.fromJson<String?>(json['color']),
      notes: serializer.fromJson<String?>(json['notes']),
      tags: serializer.fromJson<String?>(json['tags']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
      updatedAt: serializer.fromJson<DateTime>(json['updatedAt']),
      lastConnectedAt: serializer.fromJson<DateTime?>(json['lastConnectedAt']),
      terminalThemeLightId: serializer.fromJson<String?>(
        json['terminalThemeLightId'],
      ),
      terminalThemeDarkId: serializer.fromJson<String?>(
        json['terminalThemeDarkId'],
      ),
      terminalFontFamily: serializer.fromJson<String?>(
        json['terminalFontFamily'],
      ),
      autoConnectCommand: serializer.fromJson<String?>(
        json['autoConnectCommand'],
      ),
      autoConnectSnippetId: serializer.fromJson<int?>(
        json['autoConnectSnippetId'],
      ),
      autoConnectRequiresConfirmation: serializer.fromJson<bool>(
        json['autoConnectRequiresConfirmation'],
      ),
      tmuxSessionName: serializer.fromJson<String?>(json['tmuxSessionName']),
      tmuxWorkingDirectory: serializer.fromJson<String?>(
        json['tmuxWorkingDirectory'],
      ),
      tmuxExtraFlags: serializer.fromJson<String?>(json['tmuxExtraFlags']),
      remoteMuxBackend: serializer.fromJson<String?>(json['remoteMuxBackend']),
      autoForwardPorts: serializer.fromJson<bool>(json['autoForwardPorts']),
      portProxyName: serializer.fromJson<String?>(json['portProxyName']),
      sortOrder: serializer.fromJson<int>(json['sortOrder']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'label': serializer.toJson<String>(label),
      'hostname': serializer.toJson<String>(hostname),
      'port': serializer.toJson<int>(port),
      'username': serializer.toJson<String>(username),
      'password': serializer.toJson<String?>(password),
      'keyId': serializer.toJson<int?>(keyId),
      'groupId': serializer.toJson<int?>(groupId),
      'jumpHostId': serializer.toJson<int?>(jumpHostId),
      'skipJumpHostOnSsids': serializer.toJson<String?>(skipJumpHostOnSsids),
      'isFavorite': serializer.toJson<bool>(isFavorite),
      'color': serializer.toJson<String?>(color),
      'notes': serializer.toJson<String?>(notes),
      'tags': serializer.toJson<String?>(tags),
      'createdAt': serializer.toJson<DateTime>(createdAt),
      'updatedAt': serializer.toJson<DateTime>(updatedAt),
      'lastConnectedAt': serializer.toJson<DateTime?>(lastConnectedAt),
      'terminalThemeLightId': serializer.toJson<String?>(terminalThemeLightId),
      'terminalThemeDarkId': serializer.toJson<String?>(terminalThemeDarkId),
      'terminalFontFamily': serializer.toJson<String?>(terminalFontFamily),
      'autoConnectCommand': serializer.toJson<String?>(autoConnectCommand),
      'autoConnectSnippetId': serializer.toJson<int?>(autoConnectSnippetId),
      'autoConnectRequiresConfirmation': serializer.toJson<bool>(
        autoConnectRequiresConfirmation,
      ),
      'tmuxSessionName': serializer.toJson<String?>(tmuxSessionName),
      'tmuxWorkingDirectory': serializer.toJson<String?>(tmuxWorkingDirectory),
      'tmuxExtraFlags': serializer.toJson<String?>(tmuxExtraFlags),
      'remoteMuxBackend': serializer.toJson<String?>(remoteMuxBackend),
      'autoForwardPorts': serializer.toJson<bool>(autoForwardPorts),
      'portProxyName': serializer.toJson<String?>(portProxyName),
      'sortOrder': serializer.toJson<int>(sortOrder),
    };
  }

  Host copyWith({
    int? id,
    String? label,
    String? hostname,
    int? port,
    String? username,
    Value<String?> password = const Value.absent(),
    Value<int?> keyId = const Value.absent(),
    Value<int?> groupId = const Value.absent(),
    Value<int?> jumpHostId = const Value.absent(),
    Value<String?> skipJumpHostOnSsids = const Value.absent(),
    bool? isFavorite,
    Value<String?> color = const Value.absent(),
    Value<String?> notes = const Value.absent(),
    Value<String?> tags = const Value.absent(),
    DateTime? createdAt,
    DateTime? updatedAt,
    Value<DateTime?> lastConnectedAt = const Value.absent(),
    Value<String?> terminalThemeLightId = const Value.absent(),
    Value<String?> terminalThemeDarkId = const Value.absent(),
    Value<String?> terminalFontFamily = const Value.absent(),
    Value<String?> autoConnectCommand = const Value.absent(),
    Value<int?> autoConnectSnippetId = const Value.absent(),
    bool? autoConnectRequiresConfirmation,
    Value<String?> tmuxSessionName = const Value.absent(),
    Value<String?> tmuxWorkingDirectory = const Value.absent(),
    Value<String?> tmuxExtraFlags = const Value.absent(),
    Value<String?> remoteMuxBackend = const Value.absent(),
    bool? autoForwardPorts,
    Value<String?> portProxyName = const Value.absent(),
    int? sortOrder,
  }) => Host(
    id: id ?? this.id,
    label: label ?? this.label,
    hostname: hostname ?? this.hostname,
    port: port ?? this.port,
    username: username ?? this.username,
    password: password.present ? password.value : this.password,
    keyId: keyId.present ? keyId.value : this.keyId,
    groupId: groupId.present ? groupId.value : this.groupId,
    jumpHostId: jumpHostId.present ? jumpHostId.value : this.jumpHostId,
    skipJumpHostOnSsids: skipJumpHostOnSsids.present
        ? skipJumpHostOnSsids.value
        : this.skipJumpHostOnSsids,
    isFavorite: isFavorite ?? this.isFavorite,
    color: color.present ? color.value : this.color,
    notes: notes.present ? notes.value : this.notes,
    tags: tags.present ? tags.value : this.tags,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    lastConnectedAt: lastConnectedAt.present
        ? lastConnectedAt.value
        : this.lastConnectedAt,
    terminalThemeLightId: terminalThemeLightId.present
        ? terminalThemeLightId.value
        : this.terminalThemeLightId,
    terminalThemeDarkId: terminalThemeDarkId.present
        ? terminalThemeDarkId.value
        : this.terminalThemeDarkId,
    terminalFontFamily: terminalFontFamily.present
        ? terminalFontFamily.value
        : this.terminalFontFamily,
    autoConnectCommand: autoConnectCommand.present
        ? autoConnectCommand.value
        : this.autoConnectCommand,
    autoConnectSnippetId: autoConnectSnippetId.present
        ? autoConnectSnippetId.value
        : this.autoConnectSnippetId,
    autoConnectRequiresConfirmation:
        autoConnectRequiresConfirmation ?? this.autoConnectRequiresConfirmation,
    tmuxSessionName: tmuxSessionName.present
        ? tmuxSessionName.value
        : this.tmuxSessionName,
    tmuxWorkingDirectory: tmuxWorkingDirectory.present
        ? tmuxWorkingDirectory.value
        : this.tmuxWorkingDirectory,
    tmuxExtraFlags: tmuxExtraFlags.present
        ? tmuxExtraFlags.value
        : this.tmuxExtraFlags,
    remoteMuxBackend: remoteMuxBackend.present
        ? remoteMuxBackend.value
        : this.remoteMuxBackend,
    autoForwardPorts: autoForwardPorts ?? this.autoForwardPorts,
    portProxyName: portProxyName.present
        ? portProxyName.value
        : this.portProxyName,
    sortOrder: sortOrder ?? this.sortOrder,
  );
  Host copyWithCompanion(HostsCompanion data) {
    return Host(
      id: data.id.present ? data.id.value : this.id,
      label: data.label.present ? data.label.value : this.label,
      hostname: data.hostname.present ? data.hostname.value : this.hostname,
      port: data.port.present ? data.port.value : this.port,
      username: data.username.present ? data.username.value : this.username,
      password: data.password.present ? data.password.value : this.password,
      keyId: data.keyId.present ? data.keyId.value : this.keyId,
      groupId: data.groupId.present ? data.groupId.value : this.groupId,
      jumpHostId: data.jumpHostId.present
          ? data.jumpHostId.value
          : this.jumpHostId,
      skipJumpHostOnSsids: data.skipJumpHostOnSsids.present
          ? data.skipJumpHostOnSsids.value
          : this.skipJumpHostOnSsids,
      isFavorite: data.isFavorite.present
          ? data.isFavorite.value
          : this.isFavorite,
      color: data.color.present ? data.color.value : this.color,
      notes: data.notes.present ? data.notes.value : this.notes,
      tags: data.tags.present ? data.tags.value : this.tags,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
      lastConnectedAt: data.lastConnectedAt.present
          ? data.lastConnectedAt.value
          : this.lastConnectedAt,
      terminalThemeLightId: data.terminalThemeLightId.present
          ? data.terminalThemeLightId.value
          : this.terminalThemeLightId,
      terminalThemeDarkId: data.terminalThemeDarkId.present
          ? data.terminalThemeDarkId.value
          : this.terminalThemeDarkId,
      terminalFontFamily: data.terminalFontFamily.present
          ? data.terminalFontFamily.value
          : this.terminalFontFamily,
      autoConnectCommand: data.autoConnectCommand.present
          ? data.autoConnectCommand.value
          : this.autoConnectCommand,
      autoConnectSnippetId: data.autoConnectSnippetId.present
          ? data.autoConnectSnippetId.value
          : this.autoConnectSnippetId,
      autoConnectRequiresConfirmation:
          data.autoConnectRequiresConfirmation.present
          ? data.autoConnectRequiresConfirmation.value
          : this.autoConnectRequiresConfirmation,
      tmuxSessionName: data.tmuxSessionName.present
          ? data.tmuxSessionName.value
          : this.tmuxSessionName,
      tmuxWorkingDirectory: data.tmuxWorkingDirectory.present
          ? data.tmuxWorkingDirectory.value
          : this.tmuxWorkingDirectory,
      tmuxExtraFlags: data.tmuxExtraFlags.present
          ? data.tmuxExtraFlags.value
          : this.tmuxExtraFlags,
      remoteMuxBackend: data.remoteMuxBackend.present
          ? data.remoteMuxBackend.value
          : this.remoteMuxBackend,
      autoForwardPorts: data.autoForwardPorts.present
          ? data.autoForwardPorts.value
          : this.autoForwardPorts,
      portProxyName: data.portProxyName.present
          ? data.portProxyName.value
          : this.portProxyName,
      sortOrder: data.sortOrder.present ? data.sortOrder.value : this.sortOrder,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Host(')
          ..write('id: $id, ')
          ..write('label: $label, ')
          ..write('hostname: $hostname, ')
          ..write('port: $port, ')
          ..write('username: $username, ')
          ..write('password: $password, ')
          ..write('keyId: $keyId, ')
          ..write('groupId: $groupId, ')
          ..write('jumpHostId: $jumpHostId, ')
          ..write('skipJumpHostOnSsids: $skipJumpHostOnSsids, ')
          ..write('isFavorite: $isFavorite, ')
          ..write('color: $color, ')
          ..write('notes: $notes, ')
          ..write('tags: $tags, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('lastConnectedAt: $lastConnectedAt, ')
          ..write('terminalThemeLightId: $terminalThemeLightId, ')
          ..write('terminalThemeDarkId: $terminalThemeDarkId, ')
          ..write('terminalFontFamily: $terminalFontFamily, ')
          ..write('autoConnectCommand: $autoConnectCommand, ')
          ..write('autoConnectSnippetId: $autoConnectSnippetId, ')
          ..write(
            'autoConnectRequiresConfirmation: $autoConnectRequiresConfirmation, ',
          )
          ..write('tmuxSessionName: $tmuxSessionName, ')
          ..write('tmuxWorkingDirectory: $tmuxWorkingDirectory, ')
          ..write('tmuxExtraFlags: $tmuxExtraFlags, ')
          ..write('remoteMuxBackend: $remoteMuxBackend, ')
          ..write('autoForwardPorts: $autoForwardPorts, ')
          ..write('portProxyName: $portProxyName, ')
          ..write('sortOrder: $sortOrder')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hashAll([
    id,
    label,
    hostname,
    port,
    username,
    password,
    keyId,
    groupId,
    jumpHostId,
    skipJumpHostOnSsids,
    isFavorite,
    color,
    notes,
    tags,
    createdAt,
    updatedAt,
    lastConnectedAt,
    terminalThemeLightId,
    terminalThemeDarkId,
    terminalFontFamily,
    autoConnectCommand,
    autoConnectSnippetId,
    autoConnectRequiresConfirmation,
    tmuxSessionName,
    tmuxWorkingDirectory,
    tmuxExtraFlags,
    remoteMuxBackend,
    autoForwardPorts,
    portProxyName,
    sortOrder,
  ]);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Host &&
          other.id == this.id &&
          other.label == this.label &&
          other.hostname == this.hostname &&
          other.port == this.port &&
          other.username == this.username &&
          other.password == this.password &&
          other.keyId == this.keyId &&
          other.groupId == this.groupId &&
          other.jumpHostId == this.jumpHostId &&
          other.skipJumpHostOnSsids == this.skipJumpHostOnSsids &&
          other.isFavorite == this.isFavorite &&
          other.color == this.color &&
          other.notes == this.notes &&
          other.tags == this.tags &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt &&
          other.lastConnectedAt == this.lastConnectedAt &&
          other.terminalThemeLightId == this.terminalThemeLightId &&
          other.terminalThemeDarkId == this.terminalThemeDarkId &&
          other.terminalFontFamily == this.terminalFontFamily &&
          other.autoConnectCommand == this.autoConnectCommand &&
          other.autoConnectSnippetId == this.autoConnectSnippetId &&
          other.autoConnectRequiresConfirmation ==
              this.autoConnectRequiresConfirmation &&
          other.tmuxSessionName == this.tmuxSessionName &&
          other.tmuxWorkingDirectory == this.tmuxWorkingDirectory &&
          other.tmuxExtraFlags == this.tmuxExtraFlags &&
          other.remoteMuxBackend == this.remoteMuxBackend &&
          other.autoForwardPorts == this.autoForwardPorts &&
          other.portProxyName == this.portProxyName &&
          other.sortOrder == this.sortOrder);
}

class HostsCompanion extends UpdateCompanion<Host> {
  final Value<int> id;
  final Value<String> label;
  final Value<String> hostname;
  final Value<int> port;
  final Value<String> username;
  final Value<String?> password;
  final Value<int?> keyId;
  final Value<int?> groupId;
  final Value<int?> jumpHostId;
  final Value<String?> skipJumpHostOnSsids;
  final Value<bool> isFavorite;
  final Value<String?> color;
  final Value<String?> notes;
  final Value<String?> tags;
  final Value<DateTime> createdAt;
  final Value<DateTime> updatedAt;
  final Value<DateTime?> lastConnectedAt;
  final Value<String?> terminalThemeLightId;
  final Value<String?> terminalThemeDarkId;
  final Value<String?> terminalFontFamily;
  final Value<String?> autoConnectCommand;
  final Value<int?> autoConnectSnippetId;
  final Value<bool> autoConnectRequiresConfirmation;
  final Value<String?> tmuxSessionName;
  final Value<String?> tmuxWorkingDirectory;
  final Value<String?> tmuxExtraFlags;
  final Value<String?> remoteMuxBackend;
  final Value<bool> autoForwardPorts;
  final Value<String?> portProxyName;
  final Value<int> sortOrder;
  const HostsCompanion({
    this.id = const Value.absent(),
    this.label = const Value.absent(),
    this.hostname = const Value.absent(),
    this.port = const Value.absent(),
    this.username = const Value.absent(),
    this.password = const Value.absent(),
    this.keyId = const Value.absent(),
    this.groupId = const Value.absent(),
    this.jumpHostId = const Value.absent(),
    this.skipJumpHostOnSsids = const Value.absent(),
    this.isFavorite = const Value.absent(),
    this.color = const Value.absent(),
    this.notes = const Value.absent(),
    this.tags = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.lastConnectedAt = const Value.absent(),
    this.terminalThemeLightId = const Value.absent(),
    this.terminalThemeDarkId = const Value.absent(),
    this.terminalFontFamily = const Value.absent(),
    this.autoConnectCommand = const Value.absent(),
    this.autoConnectSnippetId = const Value.absent(),
    this.autoConnectRequiresConfirmation = const Value.absent(),
    this.tmuxSessionName = const Value.absent(),
    this.tmuxWorkingDirectory = const Value.absent(),
    this.tmuxExtraFlags = const Value.absent(),
    this.remoteMuxBackend = const Value.absent(),
    this.autoForwardPorts = const Value.absent(),
    this.portProxyName = const Value.absent(),
    this.sortOrder = const Value.absent(),
  });
  HostsCompanion.insert({
    this.id = const Value.absent(),
    required String label,
    required String hostname,
    this.port = const Value.absent(),
    required String username,
    this.password = const Value.absent(),
    this.keyId = const Value.absent(),
    this.groupId = const Value.absent(),
    this.jumpHostId = const Value.absent(),
    this.skipJumpHostOnSsids = const Value.absent(),
    this.isFavorite = const Value.absent(),
    this.color = const Value.absent(),
    this.notes = const Value.absent(),
    this.tags = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.lastConnectedAt = const Value.absent(),
    this.terminalThemeLightId = const Value.absent(),
    this.terminalThemeDarkId = const Value.absent(),
    this.terminalFontFamily = const Value.absent(),
    this.autoConnectCommand = const Value.absent(),
    this.autoConnectSnippetId = const Value.absent(),
    this.autoConnectRequiresConfirmation = const Value.absent(),
    this.tmuxSessionName = const Value.absent(),
    this.tmuxWorkingDirectory = const Value.absent(),
    this.tmuxExtraFlags = const Value.absent(),
    this.remoteMuxBackend = const Value.absent(),
    this.autoForwardPorts = const Value.absent(),
    this.portProxyName = const Value.absent(),
    this.sortOrder = const Value.absent(),
  }) : label = Value(label),
       hostname = Value(hostname),
       username = Value(username);
  static Insertable<Host> custom({
    Expression<int>? id,
    Expression<String>? label,
    Expression<String>? hostname,
    Expression<int>? port,
    Expression<String>? username,
    Expression<String>? password,
    Expression<int>? keyId,
    Expression<int>? groupId,
    Expression<int>? jumpHostId,
    Expression<String>? skipJumpHostOnSsids,
    Expression<bool>? isFavorite,
    Expression<String>? color,
    Expression<String>? notes,
    Expression<String>? tags,
    Expression<DateTime>? createdAt,
    Expression<DateTime>? updatedAt,
    Expression<DateTime>? lastConnectedAt,
    Expression<String>? terminalThemeLightId,
    Expression<String>? terminalThemeDarkId,
    Expression<String>? terminalFontFamily,
    Expression<String>? autoConnectCommand,
    Expression<int>? autoConnectSnippetId,
    Expression<bool>? autoConnectRequiresConfirmation,
    Expression<String>? tmuxSessionName,
    Expression<String>? tmuxWorkingDirectory,
    Expression<String>? tmuxExtraFlags,
    Expression<String>? remoteMuxBackend,
    Expression<bool>? autoForwardPorts,
    Expression<String>? portProxyName,
    Expression<int>? sortOrder,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (label != null) 'label': label,
      if (hostname != null) 'hostname': hostname,
      if (port != null) 'port': port,
      if (username != null) 'username': username,
      if (password != null) 'password': password,
      if (keyId != null) 'key_id': keyId,
      if (groupId != null) 'group_id': groupId,
      if (jumpHostId != null) 'jump_host_id': jumpHostId,
      if (skipJumpHostOnSsids != null)
        'skip_jump_host_on_ssids': skipJumpHostOnSsids,
      if (isFavorite != null) 'is_favorite': isFavorite,
      if (color != null) 'color': color,
      if (notes != null) 'notes': notes,
      if (tags != null) 'tags': tags,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (lastConnectedAt != null) 'last_connected_at': lastConnectedAt,
      if (terminalThemeLightId != null)
        'terminal_theme_light_id': terminalThemeLightId,
      if (terminalThemeDarkId != null)
        'terminal_theme_dark_id': terminalThemeDarkId,
      if (terminalFontFamily != null)
        'terminal_font_family': terminalFontFamily,
      if (autoConnectCommand != null)
        'auto_connect_command': autoConnectCommand,
      if (autoConnectSnippetId != null)
        'auto_connect_snippet_id': autoConnectSnippetId,
      if (autoConnectRequiresConfirmation != null)
        'auto_connect_requires_confirmation': autoConnectRequiresConfirmation,
      if (tmuxSessionName != null) 'tmux_session_name': tmuxSessionName,
      if (tmuxWorkingDirectory != null)
        'tmux_working_directory': tmuxWorkingDirectory,
      if (tmuxExtraFlags != null) 'tmux_extra_flags': tmuxExtraFlags,
      if (remoteMuxBackend != null) 'remote_mux_backend': remoteMuxBackend,
      if (autoForwardPorts != null) 'auto_forward_ports': autoForwardPorts,
      if (portProxyName != null) 'port_proxy_name': portProxyName,
      if (sortOrder != null) 'sort_order': sortOrder,
    });
  }

  HostsCompanion copyWith({
    Value<int>? id,
    Value<String>? label,
    Value<String>? hostname,
    Value<int>? port,
    Value<String>? username,
    Value<String?>? password,
    Value<int?>? keyId,
    Value<int?>? groupId,
    Value<int?>? jumpHostId,
    Value<String?>? skipJumpHostOnSsids,
    Value<bool>? isFavorite,
    Value<String?>? color,
    Value<String?>? notes,
    Value<String?>? tags,
    Value<DateTime>? createdAt,
    Value<DateTime>? updatedAt,
    Value<DateTime?>? lastConnectedAt,
    Value<String?>? terminalThemeLightId,
    Value<String?>? terminalThemeDarkId,
    Value<String?>? terminalFontFamily,
    Value<String?>? autoConnectCommand,
    Value<int?>? autoConnectSnippetId,
    Value<bool>? autoConnectRequiresConfirmation,
    Value<String?>? tmuxSessionName,
    Value<String?>? tmuxWorkingDirectory,
    Value<String?>? tmuxExtraFlags,
    Value<String?>? remoteMuxBackend,
    Value<bool>? autoForwardPorts,
    Value<String?>? portProxyName,
    Value<int>? sortOrder,
  }) {
    return HostsCompanion(
      id: id ?? this.id,
      label: label ?? this.label,
      hostname: hostname ?? this.hostname,
      port: port ?? this.port,
      username: username ?? this.username,
      password: password ?? this.password,
      keyId: keyId ?? this.keyId,
      groupId: groupId ?? this.groupId,
      jumpHostId: jumpHostId ?? this.jumpHostId,
      skipJumpHostOnSsids: skipJumpHostOnSsids ?? this.skipJumpHostOnSsids,
      isFavorite: isFavorite ?? this.isFavorite,
      color: color ?? this.color,
      notes: notes ?? this.notes,
      tags: tags ?? this.tags,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      lastConnectedAt: lastConnectedAt ?? this.lastConnectedAt,
      terminalThemeLightId: terminalThemeLightId ?? this.terminalThemeLightId,
      terminalThemeDarkId: terminalThemeDarkId ?? this.terminalThemeDarkId,
      terminalFontFamily: terminalFontFamily ?? this.terminalFontFamily,
      autoConnectCommand: autoConnectCommand ?? this.autoConnectCommand,
      autoConnectSnippetId: autoConnectSnippetId ?? this.autoConnectSnippetId,
      autoConnectRequiresConfirmation:
          autoConnectRequiresConfirmation ??
          this.autoConnectRequiresConfirmation,
      tmuxSessionName: tmuxSessionName ?? this.tmuxSessionName,
      tmuxWorkingDirectory: tmuxWorkingDirectory ?? this.tmuxWorkingDirectory,
      tmuxExtraFlags: tmuxExtraFlags ?? this.tmuxExtraFlags,
      remoteMuxBackend: remoteMuxBackend ?? this.remoteMuxBackend,
      autoForwardPorts: autoForwardPorts ?? this.autoForwardPorts,
      portProxyName: portProxyName ?? this.portProxyName,
      sortOrder: sortOrder ?? this.sortOrder,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (label.present) {
      map['label'] = Variable<String>(label.value);
    }
    if (hostname.present) {
      map['hostname'] = Variable<String>(hostname.value);
    }
    if (port.present) {
      map['port'] = Variable<int>(port.value);
    }
    if (username.present) {
      map['username'] = Variable<String>(username.value);
    }
    if (password.present) {
      map['password'] = Variable<String>(password.value);
    }
    if (keyId.present) {
      map['key_id'] = Variable<int>(keyId.value);
    }
    if (groupId.present) {
      map['group_id'] = Variable<int>(groupId.value);
    }
    if (jumpHostId.present) {
      map['jump_host_id'] = Variable<int>(jumpHostId.value);
    }
    if (skipJumpHostOnSsids.present) {
      map['skip_jump_host_on_ssids'] = Variable<String>(
        skipJumpHostOnSsids.value,
      );
    }
    if (isFavorite.present) {
      map['is_favorite'] = Variable<bool>(isFavorite.value);
    }
    if (color.present) {
      map['color'] = Variable<String>(color.value);
    }
    if (notes.present) {
      map['notes'] = Variable<String>(notes.value);
    }
    if (tags.present) {
      map['tags'] = Variable<String>(tags.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    if (lastConnectedAt.present) {
      map['last_connected_at'] = Variable<DateTime>(lastConnectedAt.value);
    }
    if (terminalThemeLightId.present) {
      map['terminal_theme_light_id'] = Variable<String>(
        terminalThemeLightId.value,
      );
    }
    if (terminalThemeDarkId.present) {
      map['terminal_theme_dark_id'] = Variable<String>(
        terminalThemeDarkId.value,
      );
    }
    if (terminalFontFamily.present) {
      map['terminal_font_family'] = Variable<String>(terminalFontFamily.value);
    }
    if (autoConnectCommand.present) {
      map['auto_connect_command'] = Variable<String>(autoConnectCommand.value);
    }
    if (autoConnectSnippetId.present) {
      map['auto_connect_snippet_id'] = Variable<int>(
        autoConnectSnippetId.value,
      );
    }
    if (autoConnectRequiresConfirmation.present) {
      map['auto_connect_requires_confirmation'] = Variable<bool>(
        autoConnectRequiresConfirmation.value,
      );
    }
    if (tmuxSessionName.present) {
      map['tmux_session_name'] = Variable<String>(tmuxSessionName.value);
    }
    if (tmuxWorkingDirectory.present) {
      map['tmux_working_directory'] = Variable<String>(
        tmuxWorkingDirectory.value,
      );
    }
    if (tmuxExtraFlags.present) {
      map['tmux_extra_flags'] = Variable<String>(tmuxExtraFlags.value);
    }
    if (remoteMuxBackend.present) {
      map['remote_mux_backend'] = Variable<String>(remoteMuxBackend.value);
    }
    if (autoForwardPorts.present) {
      map['auto_forward_ports'] = Variable<bool>(autoForwardPorts.value);
    }
    if (portProxyName.present) {
      map['port_proxy_name'] = Variable<String>(portProxyName.value);
    }
    if (sortOrder.present) {
      map['sort_order'] = Variable<int>(sortOrder.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('HostsCompanion(')
          ..write('id: $id, ')
          ..write('label: $label, ')
          ..write('hostname: $hostname, ')
          ..write('port: $port, ')
          ..write('username: $username, ')
          ..write('password: $password, ')
          ..write('keyId: $keyId, ')
          ..write('groupId: $groupId, ')
          ..write('jumpHostId: $jumpHostId, ')
          ..write('skipJumpHostOnSsids: $skipJumpHostOnSsids, ')
          ..write('isFavorite: $isFavorite, ')
          ..write('color: $color, ')
          ..write('notes: $notes, ')
          ..write('tags: $tags, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('lastConnectedAt: $lastConnectedAt, ')
          ..write('terminalThemeLightId: $terminalThemeLightId, ')
          ..write('terminalThemeDarkId: $terminalThemeDarkId, ')
          ..write('terminalFontFamily: $terminalFontFamily, ')
          ..write('autoConnectCommand: $autoConnectCommand, ')
          ..write('autoConnectSnippetId: $autoConnectSnippetId, ')
          ..write(
            'autoConnectRequiresConfirmation: $autoConnectRequiresConfirmation, ',
          )
          ..write('tmuxSessionName: $tmuxSessionName, ')
          ..write('tmuxWorkingDirectory: $tmuxWorkingDirectory, ')
          ..write('tmuxExtraFlags: $tmuxExtraFlags, ')
          ..write('remoteMuxBackend: $remoteMuxBackend, ')
          ..write('autoForwardPorts: $autoForwardPorts, ')
          ..write('portProxyName: $portProxyName, ')
          ..write('sortOrder: $sortOrder')
          ..write(')'))
        .toString();
  }
}

class $PortForwardsTable extends PortForwards
    with TableInfo<$PortForwardsTable, PortForward> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $PortForwardsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    additionalChecks: GeneratedColumn.checkTextLength(
      minTextLength: 1,
      maxTextLength: 255,
    ),
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _hostIdMeta = const VerificationMeta('hostId');
  @override
  late final GeneratedColumn<int> hostId = GeneratedColumn<int>(
    'host_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES hosts (id)',
    ),
  );
  static const VerificationMeta _forwardTypeMeta = const VerificationMeta(
    'forwardType',
  );
  @override
  late final GeneratedColumn<String> forwardType = GeneratedColumn<String>(
    'forward_type',
    aliasedName,
    false,
    additionalChecks: GeneratedColumn.checkTextLength(
      minTextLength: 1,
      maxTextLength: 10,
    ),
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _localHostMeta = const VerificationMeta(
    'localHost',
  );
  @override
  late final GeneratedColumn<String> localHost = GeneratedColumn<String>(
    'local_host',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('127.0.0.1'),
  );
  static const VerificationMeta _localPortMeta = const VerificationMeta(
    'localPort',
  );
  @override
  late final GeneratedColumn<int> localPort = GeneratedColumn<int>(
    'local_port',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _remoteHostMeta = const VerificationMeta(
    'remoteHost',
  );
  @override
  late final GeneratedColumn<String> remoteHost = GeneratedColumn<String>(
    'remote_host',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _remotePortMeta = const VerificationMeta(
    'remotePort',
  );
  @override
  late final GeneratedColumn<int> remotePort = GeneratedColumn<int>(
    'remote_port',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _autoStartMeta = const VerificationMeta(
    'autoStart',
  );
  @override
  late final GeneratedColumn<bool> autoStart = GeneratedColumn<bool>(
    'auto_start',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("auto_start" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
    defaultValue: currentDateAndTime,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    name,
    hostId,
    forwardType,
    localHost,
    localPort,
    remoteHost,
    remotePort,
    autoStart,
    createdAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'port_forwards';
  @override
  VerificationContext validateIntegrity(
    Insertable<PortForward> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('host_id')) {
      context.handle(
        _hostIdMeta,
        hostId.isAcceptableOrUnknown(data['host_id']!, _hostIdMeta),
      );
    } else if (isInserting) {
      context.missing(_hostIdMeta);
    }
    if (data.containsKey('forward_type')) {
      context.handle(
        _forwardTypeMeta,
        forwardType.isAcceptableOrUnknown(
          data['forward_type']!,
          _forwardTypeMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_forwardTypeMeta);
    }
    if (data.containsKey('local_host')) {
      context.handle(
        _localHostMeta,
        localHost.isAcceptableOrUnknown(data['local_host']!, _localHostMeta),
      );
    }
    if (data.containsKey('local_port')) {
      context.handle(
        _localPortMeta,
        localPort.isAcceptableOrUnknown(data['local_port']!, _localPortMeta),
      );
    } else if (isInserting) {
      context.missing(_localPortMeta);
    }
    if (data.containsKey('remote_host')) {
      context.handle(
        _remoteHostMeta,
        remoteHost.isAcceptableOrUnknown(data['remote_host']!, _remoteHostMeta),
      );
    } else if (isInserting) {
      context.missing(_remoteHostMeta);
    }
    if (data.containsKey('remote_port')) {
      context.handle(
        _remotePortMeta,
        remotePort.isAcceptableOrUnknown(data['remote_port']!, _remotePortMeta),
      );
    } else if (isInserting) {
      context.missing(_remotePortMeta);
    }
    if (data.containsKey('auto_start')) {
      context.handle(
        _autoStartMeta,
        autoStart.isAcceptableOrUnknown(data['auto_start']!, _autoStartMeta),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  PortForward map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return PortForward(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      hostId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}host_id'],
      )!,
      forwardType: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}forward_type'],
      )!,
      localHost: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}local_host'],
      )!,
      localPort: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}local_port'],
      )!,
      remoteHost: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}remote_host'],
      )!,
      remotePort: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}remote_port'],
      )!,
      autoStart: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}auto_start'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}created_at'],
      )!,
    );
  }

  @override
  $PortForwardsTable createAlias(String alias) {
    return $PortForwardsTable(attachedDatabase, alias);
  }
}

class PortForward extends DataClass implements Insertable<PortForward> {
  /// Unique identifier.
  final int id;

  /// Rule name.
  final String name;

  /// Associated host.
  final int hostId;

  /// Forward type: 'local' or 'remote'.
  final String forwardType;

  /// Local bind address.
  final String localHost;

  /// Local port.
  final int localPort;

  /// Remote host.
  final String remoteHost;

  /// Remote port.
  final int remotePort;

  /// Whether to auto-start on host connection.
  final bool autoStart;

  /// Creation timestamp.
  final DateTime createdAt;
  const PortForward({
    required this.id,
    required this.name,
    required this.hostId,
    required this.forwardType,
    required this.localHost,
    required this.localPort,
    required this.remoteHost,
    required this.remotePort,
    required this.autoStart,
    required this.createdAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['name'] = Variable<String>(name);
    map['host_id'] = Variable<int>(hostId);
    map['forward_type'] = Variable<String>(forwardType);
    map['local_host'] = Variable<String>(localHost);
    map['local_port'] = Variable<int>(localPort);
    map['remote_host'] = Variable<String>(remoteHost);
    map['remote_port'] = Variable<int>(remotePort);
    map['auto_start'] = Variable<bool>(autoStart);
    map['created_at'] = Variable<DateTime>(createdAt);
    return map;
  }

  PortForwardsCompanion toCompanion(bool nullToAbsent) {
    return PortForwardsCompanion(
      id: Value(id),
      name: Value(name),
      hostId: Value(hostId),
      forwardType: Value(forwardType),
      localHost: Value(localHost),
      localPort: Value(localPort),
      remoteHost: Value(remoteHost),
      remotePort: Value(remotePort),
      autoStart: Value(autoStart),
      createdAt: Value(createdAt),
    );
  }

  factory PortForward.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return PortForward(
      id: serializer.fromJson<int>(json['id']),
      name: serializer.fromJson<String>(json['name']),
      hostId: serializer.fromJson<int>(json['hostId']),
      forwardType: serializer.fromJson<String>(json['forwardType']),
      localHost: serializer.fromJson<String>(json['localHost']),
      localPort: serializer.fromJson<int>(json['localPort']),
      remoteHost: serializer.fromJson<String>(json['remoteHost']),
      remotePort: serializer.fromJson<int>(json['remotePort']),
      autoStart: serializer.fromJson<bool>(json['autoStart']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'name': serializer.toJson<String>(name),
      'hostId': serializer.toJson<int>(hostId),
      'forwardType': serializer.toJson<String>(forwardType),
      'localHost': serializer.toJson<String>(localHost),
      'localPort': serializer.toJson<int>(localPort),
      'remoteHost': serializer.toJson<String>(remoteHost),
      'remotePort': serializer.toJson<int>(remotePort),
      'autoStart': serializer.toJson<bool>(autoStart),
      'createdAt': serializer.toJson<DateTime>(createdAt),
    };
  }

  PortForward copyWith({
    int? id,
    String? name,
    int? hostId,
    String? forwardType,
    String? localHost,
    int? localPort,
    String? remoteHost,
    int? remotePort,
    bool? autoStart,
    DateTime? createdAt,
  }) => PortForward(
    id: id ?? this.id,
    name: name ?? this.name,
    hostId: hostId ?? this.hostId,
    forwardType: forwardType ?? this.forwardType,
    localHost: localHost ?? this.localHost,
    localPort: localPort ?? this.localPort,
    remoteHost: remoteHost ?? this.remoteHost,
    remotePort: remotePort ?? this.remotePort,
    autoStart: autoStart ?? this.autoStart,
    createdAt: createdAt ?? this.createdAt,
  );
  PortForward copyWithCompanion(PortForwardsCompanion data) {
    return PortForward(
      id: data.id.present ? data.id.value : this.id,
      name: data.name.present ? data.name.value : this.name,
      hostId: data.hostId.present ? data.hostId.value : this.hostId,
      forwardType: data.forwardType.present
          ? data.forwardType.value
          : this.forwardType,
      localHost: data.localHost.present ? data.localHost.value : this.localHost,
      localPort: data.localPort.present ? data.localPort.value : this.localPort,
      remoteHost: data.remoteHost.present
          ? data.remoteHost.value
          : this.remoteHost,
      remotePort: data.remotePort.present
          ? data.remotePort.value
          : this.remotePort,
      autoStart: data.autoStart.present ? data.autoStart.value : this.autoStart,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('PortForward(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('hostId: $hostId, ')
          ..write('forwardType: $forwardType, ')
          ..write('localHost: $localHost, ')
          ..write('localPort: $localPort, ')
          ..write('remoteHost: $remoteHost, ')
          ..write('remotePort: $remotePort, ')
          ..write('autoStart: $autoStart, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    name,
    hostId,
    forwardType,
    localHost,
    localPort,
    remoteHost,
    remotePort,
    autoStart,
    createdAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is PortForward &&
          other.id == this.id &&
          other.name == this.name &&
          other.hostId == this.hostId &&
          other.forwardType == this.forwardType &&
          other.localHost == this.localHost &&
          other.localPort == this.localPort &&
          other.remoteHost == this.remoteHost &&
          other.remotePort == this.remotePort &&
          other.autoStart == this.autoStart &&
          other.createdAt == this.createdAt);
}

class PortForwardsCompanion extends UpdateCompanion<PortForward> {
  final Value<int> id;
  final Value<String> name;
  final Value<int> hostId;
  final Value<String> forwardType;
  final Value<String> localHost;
  final Value<int> localPort;
  final Value<String> remoteHost;
  final Value<int> remotePort;
  final Value<bool> autoStart;
  final Value<DateTime> createdAt;
  const PortForwardsCompanion({
    this.id = const Value.absent(),
    this.name = const Value.absent(),
    this.hostId = const Value.absent(),
    this.forwardType = const Value.absent(),
    this.localHost = const Value.absent(),
    this.localPort = const Value.absent(),
    this.remoteHost = const Value.absent(),
    this.remotePort = const Value.absent(),
    this.autoStart = const Value.absent(),
    this.createdAt = const Value.absent(),
  });
  PortForwardsCompanion.insert({
    this.id = const Value.absent(),
    required String name,
    required int hostId,
    required String forwardType,
    this.localHost = const Value.absent(),
    required int localPort,
    required String remoteHost,
    required int remotePort,
    this.autoStart = const Value.absent(),
    this.createdAt = const Value.absent(),
  }) : name = Value(name),
       hostId = Value(hostId),
       forwardType = Value(forwardType),
       localPort = Value(localPort),
       remoteHost = Value(remoteHost),
       remotePort = Value(remotePort);
  static Insertable<PortForward> custom({
    Expression<int>? id,
    Expression<String>? name,
    Expression<int>? hostId,
    Expression<String>? forwardType,
    Expression<String>? localHost,
    Expression<int>? localPort,
    Expression<String>? remoteHost,
    Expression<int>? remotePort,
    Expression<bool>? autoStart,
    Expression<DateTime>? createdAt,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (name != null) 'name': name,
      if (hostId != null) 'host_id': hostId,
      if (forwardType != null) 'forward_type': forwardType,
      if (localHost != null) 'local_host': localHost,
      if (localPort != null) 'local_port': localPort,
      if (remoteHost != null) 'remote_host': remoteHost,
      if (remotePort != null) 'remote_port': remotePort,
      if (autoStart != null) 'auto_start': autoStart,
      if (createdAt != null) 'created_at': createdAt,
    });
  }

  PortForwardsCompanion copyWith({
    Value<int>? id,
    Value<String>? name,
    Value<int>? hostId,
    Value<String>? forwardType,
    Value<String>? localHost,
    Value<int>? localPort,
    Value<String>? remoteHost,
    Value<int>? remotePort,
    Value<bool>? autoStart,
    Value<DateTime>? createdAt,
  }) {
    return PortForwardsCompanion(
      id: id ?? this.id,
      name: name ?? this.name,
      hostId: hostId ?? this.hostId,
      forwardType: forwardType ?? this.forwardType,
      localHost: localHost ?? this.localHost,
      localPort: localPort ?? this.localPort,
      remoteHost: remoteHost ?? this.remoteHost,
      remotePort: remotePort ?? this.remotePort,
      autoStart: autoStart ?? this.autoStart,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (hostId.present) {
      map['host_id'] = Variable<int>(hostId.value);
    }
    if (forwardType.present) {
      map['forward_type'] = Variable<String>(forwardType.value);
    }
    if (localHost.present) {
      map['local_host'] = Variable<String>(localHost.value);
    }
    if (localPort.present) {
      map['local_port'] = Variable<int>(localPort.value);
    }
    if (remoteHost.present) {
      map['remote_host'] = Variable<String>(remoteHost.value);
    }
    if (remotePort.present) {
      map['remote_port'] = Variable<int>(remotePort.value);
    }
    if (autoStart.present) {
      map['auto_start'] = Variable<bool>(autoStart.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('PortForwardsCompanion(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('hostId: $hostId, ')
          ..write('forwardType: $forwardType, ')
          ..write('localHost: $localHost, ')
          ..write('localPort: $localPort, ')
          ..write('remoteHost: $remoteHost, ')
          ..write('remotePort: $remotePort, ')
          ..write('autoStart: $autoStart, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }
}

class $KnownHostsTable extends KnownHosts
    with TableInfo<$KnownHostsTable, KnownHost> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $KnownHostsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _hostnameMeta = const VerificationMeta(
    'hostname',
  );
  @override
  late final GeneratedColumn<String> hostname = GeneratedColumn<String>(
    'hostname',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _portMeta = const VerificationMeta('port');
  @override
  late final GeneratedColumn<int> port = GeneratedColumn<int>(
    'port',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _keyTypeMeta = const VerificationMeta(
    'keyType',
  );
  @override
  late final GeneratedColumn<String> keyType = GeneratedColumn<String>(
    'key_type',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _fingerprintMeta = const VerificationMeta(
    'fingerprint',
  );
  @override
  late final GeneratedColumn<String> fingerprint = GeneratedColumn<String>(
    'fingerprint',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _hostKeyMeta = const VerificationMeta(
    'hostKey',
  );
  @override
  late final GeneratedColumn<String> hostKey = GeneratedColumn<String>(
    'host_key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _firstSeenMeta = const VerificationMeta(
    'firstSeen',
  );
  @override
  late final GeneratedColumn<DateTime> firstSeen = GeneratedColumn<DateTime>(
    'first_seen',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
    defaultValue: currentDateAndTime,
  );
  static const VerificationMeta _lastSeenMeta = const VerificationMeta(
    'lastSeen',
  );
  @override
  late final GeneratedColumn<DateTime> lastSeen = GeneratedColumn<DateTime>(
    'last_seen',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
    defaultValue: currentDateAndTime,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    hostname,
    port,
    keyType,
    fingerprint,
    hostKey,
    firstSeen,
    lastSeen,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'known_hosts';
  @override
  VerificationContext validateIntegrity(
    Insertable<KnownHost> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('hostname')) {
      context.handle(
        _hostnameMeta,
        hostname.isAcceptableOrUnknown(data['hostname']!, _hostnameMeta),
      );
    } else if (isInserting) {
      context.missing(_hostnameMeta);
    }
    if (data.containsKey('port')) {
      context.handle(
        _portMeta,
        port.isAcceptableOrUnknown(data['port']!, _portMeta),
      );
    } else if (isInserting) {
      context.missing(_portMeta);
    }
    if (data.containsKey('key_type')) {
      context.handle(
        _keyTypeMeta,
        keyType.isAcceptableOrUnknown(data['key_type']!, _keyTypeMeta),
      );
    } else if (isInserting) {
      context.missing(_keyTypeMeta);
    }
    if (data.containsKey('fingerprint')) {
      context.handle(
        _fingerprintMeta,
        fingerprint.isAcceptableOrUnknown(
          data['fingerprint']!,
          _fingerprintMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_fingerprintMeta);
    }
    if (data.containsKey('host_key')) {
      context.handle(
        _hostKeyMeta,
        hostKey.isAcceptableOrUnknown(data['host_key']!, _hostKeyMeta),
      );
    } else if (isInserting) {
      context.missing(_hostKeyMeta);
    }
    if (data.containsKey('first_seen')) {
      context.handle(
        _firstSeenMeta,
        firstSeen.isAcceptableOrUnknown(data['first_seen']!, _firstSeenMeta),
      );
    }
    if (data.containsKey('last_seen')) {
      context.handle(
        _lastSeenMeta,
        lastSeen.isAcceptableOrUnknown(data['last_seen']!, _lastSeenMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  List<Set<GeneratedColumn>> get uniqueKeys => [
    {hostname, port},
  ];
  @override
  KnownHost map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return KnownHost(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      hostname: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}hostname'],
      )!,
      port: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}port'],
      )!,
      keyType: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}key_type'],
      )!,
      fingerprint: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}fingerprint'],
      )!,
      hostKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}host_key'],
      )!,
      firstSeen: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}first_seen'],
      )!,
      lastSeen: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}last_seen'],
      )!,
    );
  }

  @override
  $KnownHostsTable createAlias(String alias) {
    return $KnownHostsTable(attachedDatabase, alias);
  }
}

class KnownHost extends DataClass implements Insertable<KnownHost> {
  /// Unique identifier.
  final int id;

  /// Hostname or IP.
  final String hostname;

  /// Port number.
  final int port;

  /// Host key type.
  final String keyType;

  /// Host key fingerprint.
  final String fingerprint;

  /// Full host key.
  final String hostKey;

  /// When the key was first seen.
  final DateTime firstSeen;

  /// When the key was last verified.
  final DateTime lastSeen;
  const KnownHost({
    required this.id,
    required this.hostname,
    required this.port,
    required this.keyType,
    required this.fingerprint,
    required this.hostKey,
    required this.firstSeen,
    required this.lastSeen,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['hostname'] = Variable<String>(hostname);
    map['port'] = Variable<int>(port);
    map['key_type'] = Variable<String>(keyType);
    map['fingerprint'] = Variable<String>(fingerprint);
    map['host_key'] = Variable<String>(hostKey);
    map['first_seen'] = Variable<DateTime>(firstSeen);
    map['last_seen'] = Variable<DateTime>(lastSeen);
    return map;
  }

  KnownHostsCompanion toCompanion(bool nullToAbsent) {
    return KnownHostsCompanion(
      id: Value(id),
      hostname: Value(hostname),
      port: Value(port),
      keyType: Value(keyType),
      fingerprint: Value(fingerprint),
      hostKey: Value(hostKey),
      firstSeen: Value(firstSeen),
      lastSeen: Value(lastSeen),
    );
  }

  factory KnownHost.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return KnownHost(
      id: serializer.fromJson<int>(json['id']),
      hostname: serializer.fromJson<String>(json['hostname']),
      port: serializer.fromJson<int>(json['port']),
      keyType: serializer.fromJson<String>(json['keyType']),
      fingerprint: serializer.fromJson<String>(json['fingerprint']),
      hostKey: serializer.fromJson<String>(json['hostKey']),
      firstSeen: serializer.fromJson<DateTime>(json['firstSeen']),
      lastSeen: serializer.fromJson<DateTime>(json['lastSeen']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'hostname': serializer.toJson<String>(hostname),
      'port': serializer.toJson<int>(port),
      'keyType': serializer.toJson<String>(keyType),
      'fingerprint': serializer.toJson<String>(fingerprint),
      'hostKey': serializer.toJson<String>(hostKey),
      'firstSeen': serializer.toJson<DateTime>(firstSeen),
      'lastSeen': serializer.toJson<DateTime>(lastSeen),
    };
  }

  KnownHost copyWith({
    int? id,
    String? hostname,
    int? port,
    String? keyType,
    String? fingerprint,
    String? hostKey,
    DateTime? firstSeen,
    DateTime? lastSeen,
  }) => KnownHost(
    id: id ?? this.id,
    hostname: hostname ?? this.hostname,
    port: port ?? this.port,
    keyType: keyType ?? this.keyType,
    fingerprint: fingerprint ?? this.fingerprint,
    hostKey: hostKey ?? this.hostKey,
    firstSeen: firstSeen ?? this.firstSeen,
    lastSeen: lastSeen ?? this.lastSeen,
  );
  KnownHost copyWithCompanion(KnownHostsCompanion data) {
    return KnownHost(
      id: data.id.present ? data.id.value : this.id,
      hostname: data.hostname.present ? data.hostname.value : this.hostname,
      port: data.port.present ? data.port.value : this.port,
      keyType: data.keyType.present ? data.keyType.value : this.keyType,
      fingerprint: data.fingerprint.present
          ? data.fingerprint.value
          : this.fingerprint,
      hostKey: data.hostKey.present ? data.hostKey.value : this.hostKey,
      firstSeen: data.firstSeen.present ? data.firstSeen.value : this.firstSeen,
      lastSeen: data.lastSeen.present ? data.lastSeen.value : this.lastSeen,
    );
  }

  @override
  String toString() {
    return (StringBuffer('KnownHost(')
          ..write('id: $id, ')
          ..write('hostname: $hostname, ')
          ..write('port: $port, ')
          ..write('keyType: $keyType, ')
          ..write('fingerprint: $fingerprint, ')
          ..write('hostKey: $hostKey, ')
          ..write('firstSeen: $firstSeen, ')
          ..write('lastSeen: $lastSeen')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    hostname,
    port,
    keyType,
    fingerprint,
    hostKey,
    firstSeen,
    lastSeen,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is KnownHost &&
          other.id == this.id &&
          other.hostname == this.hostname &&
          other.port == this.port &&
          other.keyType == this.keyType &&
          other.fingerprint == this.fingerprint &&
          other.hostKey == this.hostKey &&
          other.firstSeen == this.firstSeen &&
          other.lastSeen == this.lastSeen);
}

class KnownHostsCompanion extends UpdateCompanion<KnownHost> {
  final Value<int> id;
  final Value<String> hostname;
  final Value<int> port;
  final Value<String> keyType;
  final Value<String> fingerprint;
  final Value<String> hostKey;
  final Value<DateTime> firstSeen;
  final Value<DateTime> lastSeen;
  const KnownHostsCompanion({
    this.id = const Value.absent(),
    this.hostname = const Value.absent(),
    this.port = const Value.absent(),
    this.keyType = const Value.absent(),
    this.fingerprint = const Value.absent(),
    this.hostKey = const Value.absent(),
    this.firstSeen = const Value.absent(),
    this.lastSeen = const Value.absent(),
  });
  KnownHostsCompanion.insert({
    this.id = const Value.absent(),
    required String hostname,
    required int port,
    required String keyType,
    required String fingerprint,
    required String hostKey,
    this.firstSeen = const Value.absent(),
    this.lastSeen = const Value.absent(),
  }) : hostname = Value(hostname),
       port = Value(port),
       keyType = Value(keyType),
       fingerprint = Value(fingerprint),
       hostKey = Value(hostKey);
  static Insertable<KnownHost> custom({
    Expression<int>? id,
    Expression<String>? hostname,
    Expression<int>? port,
    Expression<String>? keyType,
    Expression<String>? fingerprint,
    Expression<String>? hostKey,
    Expression<DateTime>? firstSeen,
    Expression<DateTime>? lastSeen,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (hostname != null) 'hostname': hostname,
      if (port != null) 'port': port,
      if (keyType != null) 'key_type': keyType,
      if (fingerprint != null) 'fingerprint': fingerprint,
      if (hostKey != null) 'host_key': hostKey,
      if (firstSeen != null) 'first_seen': firstSeen,
      if (lastSeen != null) 'last_seen': lastSeen,
    });
  }

  KnownHostsCompanion copyWith({
    Value<int>? id,
    Value<String>? hostname,
    Value<int>? port,
    Value<String>? keyType,
    Value<String>? fingerprint,
    Value<String>? hostKey,
    Value<DateTime>? firstSeen,
    Value<DateTime>? lastSeen,
  }) {
    return KnownHostsCompanion(
      id: id ?? this.id,
      hostname: hostname ?? this.hostname,
      port: port ?? this.port,
      keyType: keyType ?? this.keyType,
      fingerprint: fingerprint ?? this.fingerprint,
      hostKey: hostKey ?? this.hostKey,
      firstSeen: firstSeen ?? this.firstSeen,
      lastSeen: lastSeen ?? this.lastSeen,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (hostname.present) {
      map['hostname'] = Variable<String>(hostname.value);
    }
    if (port.present) {
      map['port'] = Variable<int>(port.value);
    }
    if (keyType.present) {
      map['key_type'] = Variable<String>(keyType.value);
    }
    if (fingerprint.present) {
      map['fingerprint'] = Variable<String>(fingerprint.value);
    }
    if (hostKey.present) {
      map['host_key'] = Variable<String>(hostKey.value);
    }
    if (firstSeen.present) {
      map['first_seen'] = Variable<DateTime>(firstSeen.value);
    }
    if (lastSeen.present) {
      map['last_seen'] = Variable<DateTime>(lastSeen.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('KnownHostsCompanion(')
          ..write('id: $id, ')
          ..write('hostname: $hostname, ')
          ..write('port: $port, ')
          ..write('keyType: $keyType, ')
          ..write('fingerprint: $fingerprint, ')
          ..write('hostKey: $hostKey, ')
          ..write('firstSeen: $firstSeen, ')
          ..write('lastSeen: $lastSeen')
          ..write(')'))
        .toString();
  }
}

class $SettingsTable extends Settings with TableInfo<$SettingsTable, Setting> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SettingsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _keyMeta = const VerificationMeta('key');
  @override
  late final GeneratedColumn<String> key = GeneratedColumn<String>(
    'key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _valueMeta = const VerificationMeta('value');
  @override
  late final GeneratedColumn<String> value = GeneratedColumn<String>(
    'value',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [key, value];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'settings';
  @override
  VerificationContext validateIntegrity(
    Insertable<Setting> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('key')) {
      context.handle(
        _keyMeta,
        key.isAcceptableOrUnknown(data['key']!, _keyMeta),
      );
    } else if (isInserting) {
      context.missing(_keyMeta);
    }
    if (data.containsKey('value')) {
      context.handle(
        _valueMeta,
        value.isAcceptableOrUnknown(data['value']!, _valueMeta),
      );
    } else if (isInserting) {
      context.missing(_valueMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {key};
  @override
  Setting map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Setting(
      key: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}key'],
      )!,
      value: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}value'],
      )!,
    );
  }

  @override
  $SettingsTable createAlias(String alias) {
    return $SettingsTable(attachedDatabase, alias);
  }
}

class Setting extends DataClass implements Insertable<Setting> {
  /// Setting key.
  final String key;

  /// Setting value (JSON encoded for complex values).
  final String value;
  const Setting({required this.key, required this.value});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['key'] = Variable<String>(key);
    map['value'] = Variable<String>(value);
    return map;
  }

  SettingsCompanion toCompanion(bool nullToAbsent) {
    return SettingsCompanion(key: Value(key), value: Value(value));
  }

  factory Setting.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Setting(
      key: serializer.fromJson<String>(json['key']),
      value: serializer.fromJson<String>(json['value']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'key': serializer.toJson<String>(key),
      'value': serializer.toJson<String>(value),
    };
  }

  Setting copyWith({String? key, String? value}) =>
      Setting(key: key ?? this.key, value: value ?? this.value);
  Setting copyWithCompanion(SettingsCompanion data) {
    return Setting(
      key: data.key.present ? data.key.value : this.key,
      value: data.value.present ? data.value.value : this.value,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Setting(')
          ..write('key: $key, ')
          ..write('value: $value')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(key, value);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Setting && other.key == this.key && other.value == this.value);
}

class SettingsCompanion extends UpdateCompanion<Setting> {
  final Value<String> key;
  final Value<String> value;
  final Value<int> rowid;
  const SettingsCompanion({
    this.key = const Value.absent(),
    this.value = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  SettingsCompanion.insert({
    required String key,
    required String value,
    this.rowid = const Value.absent(),
  }) : key = Value(key),
       value = Value(value);
  static Insertable<Setting> custom({
    Expression<String>? key,
    Expression<String>? value,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (key != null) 'key': key,
      if (value != null) 'value': value,
      if (rowid != null) 'rowid': rowid,
    });
  }

  SettingsCompanion copyWith({
    Value<String>? key,
    Value<String>? value,
    Value<int>? rowid,
  }) {
    return SettingsCompanion(
      key: key ?? this.key,
      value: value ?? this.value,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (key.present) {
      map['key'] = Variable<String>(key.value);
    }
    if (value.present) {
      map['value'] = Variable<String>(value.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SettingsCompanion(')
          ..write('key: $key, ')
          ..write('value: $value, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$AppDatabase extends GeneratedDatabase {
  _$AppDatabase(QueryExecutor e) : super(e);
  $AppDatabaseManager get managers => $AppDatabaseManager(this);
  late final $SshKeysTable sshKeys = $SshKeysTable(this);
  late final $GroupsTable groups = $GroupsTable(this);
  late final $SnippetFoldersTable snippetFolders = $SnippetFoldersTable(this);
  late final $SnippetsTable snippets = $SnippetsTable(this);
  late final $HostsTable hosts = $HostsTable(this);
  late final $PortForwardsTable portForwards = $PortForwardsTable(this);
  late final $KnownHostsTable knownHosts = $KnownHostsTable(this);
  late final $SettingsTable settings = $SettingsTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    sshKeys,
    groups,
    snippetFolders,
    snippets,
    hosts,
    portForwards,
    knownHosts,
    settings,
  ];
}

typedef $$SshKeysTableCreateCompanionBuilder =
    SshKeysCompanion Function({
      Value<int> id,
      required String name,
      required String keyType,
      required String publicKey,
      required String privateKey,
      Value<String?> passphrase,
      Value<String?> fingerprint,
      Value<DateTime> createdAt,
    });
typedef $$SshKeysTableUpdateCompanionBuilder =
    SshKeysCompanion Function({
      Value<int> id,
      Value<String> name,
      Value<String> keyType,
      Value<String> publicKey,
      Value<String> privateKey,
      Value<String?> passphrase,
      Value<String?> fingerprint,
      Value<DateTime> createdAt,
    });

final class $$SshKeysTableReferences
    extends BaseReferences<_$AppDatabase, $SshKeysTable, SshKey> {
  $$SshKeysTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static MultiTypedResultKey<$HostsTable, List<Host>> _hostsRefsTable(
    _$AppDatabase db,
  ) => MultiTypedResultKey.fromTable(
    db.hosts,
    aliasName: 'ssh_keys__id__hosts__key_id',
  );

  $$HostsTableProcessedTableManager get hostsRefs {
    final manager = $$HostsTableTableManager(
      $_db,
      $_db.hosts,
    ).filter((f) => f.keyId.id.sqlEquals($_itemColumn<int>('id')!));

    final cache = $_typedResult.readTableOrNull(_hostsRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }
}

class $$SshKeysTableFilterComposer
    extends Composer<_$AppDatabase, $SshKeysTable> {
  $$SshKeysTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get keyType => $composableBuilder(
    column: $table.keyType,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get publicKey => $composableBuilder(
    column: $table.publicKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get privateKey => $composableBuilder(
    column: $table.privateKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get passphrase => $composableBuilder(
    column: $table.passphrase,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get fingerprint => $composableBuilder(
    column: $table.fingerprint,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  Expression<bool> hostsRefs(
    Expression<bool> Function($$HostsTableFilterComposer f) f,
  ) {
    final $$HostsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.hosts,
      getReferencedColumn: (t) => t.keyId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$HostsTableFilterComposer(
            $db: $db,
            $table: $db.hosts,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$SshKeysTableOrderingComposer
    extends Composer<_$AppDatabase, $SshKeysTable> {
  $$SshKeysTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get keyType => $composableBuilder(
    column: $table.keyType,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get publicKey => $composableBuilder(
    column: $table.publicKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get privateKey => $composableBuilder(
    column: $table.privateKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get passphrase => $composableBuilder(
    column: $table.passphrase,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get fingerprint => $composableBuilder(
    column: $table.fingerprint,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$SshKeysTableAnnotationComposer
    extends Composer<_$AppDatabase, $SshKeysTable> {
  $$SshKeysTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<String> get keyType =>
      $composableBuilder(column: $table.keyType, builder: (column) => column);

  GeneratedColumn<String> get publicKey =>
      $composableBuilder(column: $table.publicKey, builder: (column) => column);

  GeneratedColumn<String> get privateKey => $composableBuilder(
    column: $table.privateKey,
    builder: (column) => column,
  );

  GeneratedColumn<String> get passphrase => $composableBuilder(
    column: $table.passphrase,
    builder: (column) => column,
  );

  GeneratedColumn<String> get fingerprint => $composableBuilder(
    column: $table.fingerprint,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  Expression<T> hostsRefs<T extends Object>(
    Expression<T> Function($$HostsTableAnnotationComposer a) f,
  ) {
    final $$HostsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.hosts,
      getReferencedColumn: (t) => t.keyId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$HostsTableAnnotationComposer(
            $db: $db,
            $table: $db.hosts,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$SshKeysTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $SshKeysTable,
          SshKey,
          $$SshKeysTableFilterComposer,
          $$SshKeysTableOrderingComposer,
          $$SshKeysTableAnnotationComposer,
          $$SshKeysTableCreateCompanionBuilder,
          $$SshKeysTableUpdateCompanionBuilder,
          (SshKey, $$SshKeysTableReferences),
          SshKey,
          PrefetchHooks Function({bool hostsRefs})
        > {
  $$SshKeysTableTableManager(_$AppDatabase db, $SshKeysTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SshKeysTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SshKeysTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SshKeysTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<String> keyType = const Value.absent(),
                Value<String> publicKey = const Value.absent(),
                Value<String> privateKey = const Value.absent(),
                Value<String?> passphrase = const Value.absent(),
                Value<String?> fingerprint = const Value.absent(),
                Value<DateTime> createdAt = const Value.absent(),
              }) => SshKeysCompanion(
                id: id,
                name: name,
                keyType: keyType,
                publicKey: publicKey,
                privateKey: privateKey,
                passphrase: passphrase,
                fingerprint: fingerprint,
                createdAt: createdAt,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required String name,
                required String keyType,
                required String publicKey,
                required String privateKey,
                Value<String?> passphrase = const Value.absent(),
                Value<String?> fingerprint = const Value.absent(),
                Value<DateTime> createdAt = const Value.absent(),
              }) => SshKeysCompanion.insert(
                id: id,
                name: name,
                keyType: keyType,
                publicKey: publicKey,
                privateKey: privateKey,
                passphrase: passphrase,
                fingerprint: fingerprint,
                createdAt: createdAt,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$SshKeysTable, SshKey>(table),
                  $$SshKeysTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({hostsRefs = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [if (hostsRefs) db.hosts],
              addJoins: null,
              getPrefetchedDataCallback: (items) async {
                return [
                  if (hostsRefs)
                    await $_getPrefetchedData<SshKey, $SshKeysTable, Host>(
                      currentTable: table,
                      referencedTable: $$SshKeysTableReferences._hostsRefsTable(
                        db,
                      ),
                      managerFromTypedResult: (p0) =>
                          $$SshKeysTableReferences(db, table, p0).hostsRefs,
                      referencedItemsForCurrentItem: (item, referencedItems) =>
                          referencedItems.where((e) => e.keyId == item.id),
                      typedResults: items,
                    ),
                ];
              },
            );
          },
        ),
      );
}

typedef $$SshKeysTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $SshKeysTable,
      SshKey,
      $$SshKeysTableFilterComposer,
      $$SshKeysTableOrderingComposer,
      $$SshKeysTableAnnotationComposer,
      $$SshKeysTableCreateCompanionBuilder,
      $$SshKeysTableUpdateCompanionBuilder,
      (SshKey, $$SshKeysTableReferences),
      SshKey,
      PrefetchHooks Function({bool hostsRefs})
    >;
typedef $$GroupsTableCreateCompanionBuilder =
    GroupsCompanion Function({
      Value<int> id,
      required String name,
      Value<int?> parentId,
      Value<int> sortOrder,
      Value<String?> color,
      Value<String?> icon,
      Value<DateTime> createdAt,
    });
typedef $$GroupsTableUpdateCompanionBuilder =
    GroupsCompanion Function({
      Value<int> id,
      Value<String> name,
      Value<int?> parentId,
      Value<int> sortOrder,
      Value<String?> color,
      Value<String?> icon,
      Value<DateTime> createdAt,
    });

final class $$GroupsTableReferences
    extends BaseReferences<_$AppDatabase, $GroupsTable, Group> {
  $$GroupsTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $GroupsTable _parentIdTable(_$AppDatabase db) =>
      db.groups.createAlias('groups__parent_id__groups__id');

  $$GroupsTableProcessedTableManager? get parentId {
    final $_column = $_itemColumn<int>('parent_id');
    if ($_column == null) return null;
    final manager = $$GroupsTableTableManager(
      $_db,
      $_db.groups,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_parentIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }

  static MultiTypedResultKey<$HostsTable, List<Host>> _hostsRefsTable(
    _$AppDatabase db,
  ) => MultiTypedResultKey.fromTable(
    db.hosts,
    aliasName: 'groups__id__hosts__group_id',
  );

  $$HostsTableProcessedTableManager get hostsRefs {
    final manager = $$HostsTableTableManager(
      $_db,
      $_db.hosts,
    ).filter((f) => f.groupId.id.sqlEquals($_itemColumn<int>('id')!));

    final cache = $_typedResult.readTableOrNull(_hostsRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }
}

class $$GroupsTableFilterComposer
    extends Composer<_$AppDatabase, $GroupsTable> {
  $$GroupsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get sortOrder => $composableBuilder(
    column: $table.sortOrder,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get color => $composableBuilder(
    column: $table.color,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get icon => $composableBuilder(
    column: $table.icon,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  $$GroupsTableFilterComposer get parentId {
    final $$GroupsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.parentId,
      referencedTable: $db.groups,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$GroupsTableFilterComposer(
            $db: $db,
            $table: $db.groups,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  Expression<bool> hostsRefs(
    Expression<bool> Function($$HostsTableFilterComposer f) f,
  ) {
    final $$HostsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.hosts,
      getReferencedColumn: (t) => t.groupId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$HostsTableFilterComposer(
            $db: $db,
            $table: $db.hosts,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$GroupsTableOrderingComposer
    extends Composer<_$AppDatabase, $GroupsTable> {
  $$GroupsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get sortOrder => $composableBuilder(
    column: $table.sortOrder,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get color => $composableBuilder(
    column: $table.color,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get icon => $composableBuilder(
    column: $table.icon,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  $$GroupsTableOrderingComposer get parentId {
    final $$GroupsTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.parentId,
      referencedTable: $db.groups,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$GroupsTableOrderingComposer(
            $db: $db,
            $table: $db.groups,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$GroupsTableAnnotationComposer
    extends Composer<_$AppDatabase, $GroupsTable> {
  $$GroupsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<int> get sortOrder =>
      $composableBuilder(column: $table.sortOrder, builder: (column) => column);

  GeneratedColumn<String> get color =>
      $composableBuilder(column: $table.color, builder: (column) => column);

  GeneratedColumn<String> get icon =>
      $composableBuilder(column: $table.icon, builder: (column) => column);

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  $$GroupsTableAnnotationComposer get parentId {
    final $$GroupsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.parentId,
      referencedTable: $db.groups,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$GroupsTableAnnotationComposer(
            $db: $db,
            $table: $db.groups,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  Expression<T> hostsRefs<T extends Object>(
    Expression<T> Function($$HostsTableAnnotationComposer a) f,
  ) {
    final $$HostsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.hosts,
      getReferencedColumn: (t) => t.groupId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$HostsTableAnnotationComposer(
            $db: $db,
            $table: $db.hosts,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$GroupsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $GroupsTable,
          Group,
          $$GroupsTableFilterComposer,
          $$GroupsTableOrderingComposer,
          $$GroupsTableAnnotationComposer,
          $$GroupsTableCreateCompanionBuilder,
          $$GroupsTableUpdateCompanionBuilder,
          (Group, $$GroupsTableReferences),
          Group,
          PrefetchHooks Function({bool parentId, bool hostsRefs})
        > {
  $$GroupsTableTableManager(_$AppDatabase db, $GroupsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$GroupsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$GroupsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$GroupsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<int?> parentId = const Value.absent(),
                Value<int> sortOrder = const Value.absent(),
                Value<String?> color = const Value.absent(),
                Value<String?> icon = const Value.absent(),
                Value<DateTime> createdAt = const Value.absent(),
              }) => GroupsCompanion(
                id: id,
                name: name,
                parentId: parentId,
                sortOrder: sortOrder,
                color: color,
                icon: icon,
                createdAt: createdAt,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required String name,
                Value<int?> parentId = const Value.absent(),
                Value<int> sortOrder = const Value.absent(),
                Value<String?> color = const Value.absent(),
                Value<String?> icon = const Value.absent(),
                Value<DateTime> createdAt = const Value.absent(),
              }) => GroupsCompanion.insert(
                id: id,
                name: name,
                parentId: parentId,
                sortOrder: sortOrder,
                color: color,
                icon: icon,
                createdAt: createdAt,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$GroupsTable, Group>(table),
                  $$GroupsTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({parentId = false, hostsRefs = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [if (hostsRefs) db.hosts],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (parentId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.parentId,
                                referencedTable: $$GroupsTableReferences
                                    ._parentIdTable(db),
                                referencedColumn: $$GroupsTableReferences
                                    ._parentIdTable(db)
                                    .id,
                              )
                              as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [
                  if (hostsRefs)
                    await $_getPrefetchedData<Group, $GroupsTable, Host>(
                      currentTable: table,
                      referencedTable: $$GroupsTableReferences._hostsRefsTable(
                        db,
                      ),
                      managerFromTypedResult: (p0) =>
                          $$GroupsTableReferences(db, table, p0).hostsRefs,
                      referencedItemsForCurrentItem: (item, referencedItems) =>
                          referencedItems.where((e) => e.groupId == item.id),
                      typedResults: items,
                    ),
                ];
              },
            );
          },
        ),
      );
}

typedef $$GroupsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $GroupsTable,
      Group,
      $$GroupsTableFilterComposer,
      $$GroupsTableOrderingComposer,
      $$GroupsTableAnnotationComposer,
      $$GroupsTableCreateCompanionBuilder,
      $$GroupsTableUpdateCompanionBuilder,
      (Group, $$GroupsTableReferences),
      Group,
      PrefetchHooks Function({bool parentId, bool hostsRefs})
    >;
typedef $$SnippetFoldersTableCreateCompanionBuilder =
    SnippetFoldersCompanion Function({
      Value<int> id,
      required String name,
      Value<int?> parentId,
      Value<int> sortOrder,
      Value<DateTime> createdAt,
    });
typedef $$SnippetFoldersTableUpdateCompanionBuilder =
    SnippetFoldersCompanion Function({
      Value<int> id,
      Value<String> name,
      Value<int?> parentId,
      Value<int> sortOrder,
      Value<DateTime> createdAt,
    });

final class $$SnippetFoldersTableReferences
    extends BaseReferences<_$AppDatabase, $SnippetFoldersTable, SnippetFolder> {
  $$SnippetFoldersTableReferences(
    super.$_db,
    super.$_table,
    super.$_typedResult,
  );

  static $SnippetFoldersTable _parentIdTable(_$AppDatabase db) => db
      .snippetFolders
      .createAlias('snippet_folders__parent_id__snippet_folders__id');

  $$SnippetFoldersTableProcessedTableManager? get parentId {
    final $_column = $_itemColumn<int>('parent_id');
    if ($_column == null) return null;
    final manager = $$SnippetFoldersTableTableManager(
      $_db,
      $_db.snippetFolders,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_parentIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }

  static MultiTypedResultKey<$SnippetsTable, List<Snippet>> _snippetsRefsTable(
    _$AppDatabase db,
  ) => MultiTypedResultKey.fromTable(
    db.snippets,
    aliasName: 'snippet_folders__id__snippets__folder_id',
  );

  $$SnippetsTableProcessedTableManager get snippetsRefs {
    final manager = $$SnippetsTableTableManager(
      $_db,
      $_db.snippets,
    ).filter((f) => f.folderId.id.sqlEquals($_itemColumn<int>('id')!));

    final cache = $_typedResult.readTableOrNull(_snippetsRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }
}

class $$SnippetFoldersTableFilterComposer
    extends Composer<_$AppDatabase, $SnippetFoldersTable> {
  $$SnippetFoldersTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get sortOrder => $composableBuilder(
    column: $table.sortOrder,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  $$SnippetFoldersTableFilterComposer get parentId {
    final $$SnippetFoldersTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.parentId,
      referencedTable: $db.snippetFolders,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$SnippetFoldersTableFilterComposer(
            $db: $db,
            $table: $db.snippetFolders,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  Expression<bool> snippetsRefs(
    Expression<bool> Function($$SnippetsTableFilterComposer f) f,
  ) {
    final $$SnippetsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.snippets,
      getReferencedColumn: (t) => t.folderId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$SnippetsTableFilterComposer(
            $db: $db,
            $table: $db.snippets,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$SnippetFoldersTableOrderingComposer
    extends Composer<_$AppDatabase, $SnippetFoldersTable> {
  $$SnippetFoldersTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get sortOrder => $composableBuilder(
    column: $table.sortOrder,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  $$SnippetFoldersTableOrderingComposer get parentId {
    final $$SnippetFoldersTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.parentId,
      referencedTable: $db.snippetFolders,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$SnippetFoldersTableOrderingComposer(
            $db: $db,
            $table: $db.snippetFolders,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$SnippetFoldersTableAnnotationComposer
    extends Composer<_$AppDatabase, $SnippetFoldersTable> {
  $$SnippetFoldersTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<int> get sortOrder =>
      $composableBuilder(column: $table.sortOrder, builder: (column) => column);

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  $$SnippetFoldersTableAnnotationComposer get parentId {
    final $$SnippetFoldersTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.parentId,
      referencedTable: $db.snippetFolders,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$SnippetFoldersTableAnnotationComposer(
            $db: $db,
            $table: $db.snippetFolders,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  Expression<T> snippetsRefs<T extends Object>(
    Expression<T> Function($$SnippetsTableAnnotationComposer a) f,
  ) {
    final $$SnippetsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.snippets,
      getReferencedColumn: (t) => t.folderId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$SnippetsTableAnnotationComposer(
            $db: $db,
            $table: $db.snippets,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$SnippetFoldersTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $SnippetFoldersTable,
          SnippetFolder,
          $$SnippetFoldersTableFilterComposer,
          $$SnippetFoldersTableOrderingComposer,
          $$SnippetFoldersTableAnnotationComposer,
          $$SnippetFoldersTableCreateCompanionBuilder,
          $$SnippetFoldersTableUpdateCompanionBuilder,
          (SnippetFolder, $$SnippetFoldersTableReferences),
          SnippetFolder,
          PrefetchHooks Function({bool parentId, bool snippetsRefs})
        > {
  $$SnippetFoldersTableTableManager(
    _$AppDatabase db,
    $SnippetFoldersTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SnippetFoldersTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SnippetFoldersTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SnippetFoldersTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<int?> parentId = const Value.absent(),
                Value<int> sortOrder = const Value.absent(),
                Value<DateTime> createdAt = const Value.absent(),
              }) => SnippetFoldersCompanion(
                id: id,
                name: name,
                parentId: parentId,
                sortOrder: sortOrder,
                createdAt: createdAt,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required String name,
                Value<int?> parentId = const Value.absent(),
                Value<int> sortOrder = const Value.absent(),
                Value<DateTime> createdAt = const Value.absent(),
              }) => SnippetFoldersCompanion.insert(
                id: id,
                name: name,
                parentId: parentId,
                sortOrder: sortOrder,
                createdAt: createdAt,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$SnippetFoldersTable, SnippetFolder>(table),
                  $$SnippetFoldersTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({parentId = false, snippetsRefs = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [if (snippetsRefs) db.snippets],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (parentId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.parentId,
                                referencedTable: $$SnippetFoldersTableReferences
                                    ._parentIdTable(db),
                                referencedColumn:
                                    $$SnippetFoldersTableReferences
                                        ._parentIdTable(db)
                                        .id,
                              )
                              as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [
                  if (snippetsRefs)
                    await $_getPrefetchedData<
                      SnippetFolder,
                      $SnippetFoldersTable,
                      Snippet
                    >(
                      currentTable: table,
                      referencedTable: $$SnippetFoldersTableReferences
                          ._snippetsRefsTable(db),
                      managerFromTypedResult: (p0) =>
                          $$SnippetFoldersTableReferences(
                            db,
                            table,
                            p0,
                          ).snippetsRefs,
                      referencedItemsForCurrentItem: (item, referencedItems) =>
                          referencedItems.where((e) => e.folderId == item.id),
                      typedResults: items,
                    ),
                ];
              },
            );
          },
        ),
      );
}

typedef $$SnippetFoldersTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $SnippetFoldersTable,
      SnippetFolder,
      $$SnippetFoldersTableFilterComposer,
      $$SnippetFoldersTableOrderingComposer,
      $$SnippetFoldersTableAnnotationComposer,
      $$SnippetFoldersTableCreateCompanionBuilder,
      $$SnippetFoldersTableUpdateCompanionBuilder,
      (SnippetFolder, $$SnippetFoldersTableReferences),
      SnippetFolder,
      PrefetchHooks Function({bool parentId, bool snippetsRefs})
    >;
typedef $$SnippetsTableCreateCompanionBuilder =
    SnippetsCompanion Function({
      Value<int> id,
      required String name,
      required String command,
      Value<String?> description,
      Value<int?> folderId,
      Value<bool> autoExecute,
      Value<DateTime> createdAt,
      Value<DateTime?> lastUsedAt,
      Value<int> usageCount,
      Value<int> sortOrder,
    });
typedef $$SnippetsTableUpdateCompanionBuilder =
    SnippetsCompanion Function({
      Value<int> id,
      Value<String> name,
      Value<String> command,
      Value<String?> description,
      Value<int?> folderId,
      Value<bool> autoExecute,
      Value<DateTime> createdAt,
      Value<DateTime?> lastUsedAt,
      Value<int> usageCount,
      Value<int> sortOrder,
    });

final class $$SnippetsTableReferences
    extends BaseReferences<_$AppDatabase, $SnippetsTable, Snippet> {
  $$SnippetsTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $SnippetFoldersTable _folderIdTable(_$AppDatabase db) =>
      db.snippetFolders.createAlias('snippets__folder_id__snippet_folders__id');

  $$SnippetFoldersTableProcessedTableManager? get folderId {
    final $_column = $_itemColumn<int>('folder_id');
    if ($_column == null) return null;
    final manager = $$SnippetFoldersTableTableManager(
      $_db,
      $_db.snippetFolders,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_folderIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }

  static MultiTypedResultKey<$HostsTable, List<Host>> _hostsRefsTable(
    _$AppDatabase db,
  ) => MultiTypedResultKey.fromTable(
    db.hosts,
    aliasName: 'snippets__id__hosts__auto_connect_snippet_id',
  );

  $$HostsTableProcessedTableManager get hostsRefs {
    final manager = $$HostsTableTableManager($_db, $_db.hosts).filter(
      (f) => f.autoConnectSnippetId.id.sqlEquals($_itemColumn<int>('id')!),
    );

    final cache = $_typedResult.readTableOrNull(_hostsRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }
}

class $$SnippetsTableFilterComposer
    extends Composer<_$AppDatabase, $SnippetsTable> {
  $$SnippetsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get command => $composableBuilder(
    column: $table.command,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get description => $composableBuilder(
    column: $table.description,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get autoExecute => $composableBuilder(
    column: $table.autoExecute,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get lastUsedAt => $composableBuilder(
    column: $table.lastUsedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get usageCount => $composableBuilder(
    column: $table.usageCount,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get sortOrder => $composableBuilder(
    column: $table.sortOrder,
    builder: (column) => ColumnFilters(column),
  );

  $$SnippetFoldersTableFilterComposer get folderId {
    final $$SnippetFoldersTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.folderId,
      referencedTable: $db.snippetFolders,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$SnippetFoldersTableFilterComposer(
            $db: $db,
            $table: $db.snippetFolders,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  Expression<bool> hostsRefs(
    Expression<bool> Function($$HostsTableFilterComposer f) f,
  ) {
    final $$HostsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.hosts,
      getReferencedColumn: (t) => t.autoConnectSnippetId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$HostsTableFilterComposer(
            $db: $db,
            $table: $db.hosts,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$SnippetsTableOrderingComposer
    extends Composer<_$AppDatabase, $SnippetsTable> {
  $$SnippetsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get command => $composableBuilder(
    column: $table.command,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get description => $composableBuilder(
    column: $table.description,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get autoExecute => $composableBuilder(
    column: $table.autoExecute,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get lastUsedAt => $composableBuilder(
    column: $table.lastUsedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get usageCount => $composableBuilder(
    column: $table.usageCount,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get sortOrder => $composableBuilder(
    column: $table.sortOrder,
    builder: (column) => ColumnOrderings(column),
  );

  $$SnippetFoldersTableOrderingComposer get folderId {
    final $$SnippetFoldersTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.folderId,
      referencedTable: $db.snippetFolders,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$SnippetFoldersTableOrderingComposer(
            $db: $db,
            $table: $db.snippetFolders,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$SnippetsTableAnnotationComposer
    extends Composer<_$AppDatabase, $SnippetsTable> {
  $$SnippetsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<String> get command =>
      $composableBuilder(column: $table.command, builder: (column) => column);

  GeneratedColumn<String> get description => $composableBuilder(
    column: $table.description,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get autoExecute => $composableBuilder(
    column: $table.autoExecute,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<DateTime> get lastUsedAt => $composableBuilder(
    column: $table.lastUsedAt,
    builder: (column) => column,
  );

  GeneratedColumn<int> get usageCount => $composableBuilder(
    column: $table.usageCount,
    builder: (column) => column,
  );

  GeneratedColumn<int> get sortOrder =>
      $composableBuilder(column: $table.sortOrder, builder: (column) => column);

  $$SnippetFoldersTableAnnotationComposer get folderId {
    final $$SnippetFoldersTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.folderId,
      referencedTable: $db.snippetFolders,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$SnippetFoldersTableAnnotationComposer(
            $db: $db,
            $table: $db.snippetFolders,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  Expression<T> hostsRefs<T extends Object>(
    Expression<T> Function($$HostsTableAnnotationComposer a) f,
  ) {
    final $$HostsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.hosts,
      getReferencedColumn: (t) => t.autoConnectSnippetId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$HostsTableAnnotationComposer(
            $db: $db,
            $table: $db.hosts,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$SnippetsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $SnippetsTable,
          Snippet,
          $$SnippetsTableFilterComposer,
          $$SnippetsTableOrderingComposer,
          $$SnippetsTableAnnotationComposer,
          $$SnippetsTableCreateCompanionBuilder,
          $$SnippetsTableUpdateCompanionBuilder,
          (Snippet, $$SnippetsTableReferences),
          Snippet,
          PrefetchHooks Function({bool folderId, bool hostsRefs})
        > {
  $$SnippetsTableTableManager(_$AppDatabase db, $SnippetsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SnippetsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SnippetsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SnippetsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<String> command = const Value.absent(),
                Value<String?> description = const Value.absent(),
                Value<int?> folderId = const Value.absent(),
                Value<bool> autoExecute = const Value.absent(),
                Value<DateTime> createdAt = const Value.absent(),
                Value<DateTime?> lastUsedAt = const Value.absent(),
                Value<int> usageCount = const Value.absent(),
                Value<int> sortOrder = const Value.absent(),
              }) => SnippetsCompanion(
                id: id,
                name: name,
                command: command,
                description: description,
                folderId: folderId,
                autoExecute: autoExecute,
                createdAt: createdAt,
                lastUsedAt: lastUsedAt,
                usageCount: usageCount,
                sortOrder: sortOrder,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required String name,
                required String command,
                Value<String?> description = const Value.absent(),
                Value<int?> folderId = const Value.absent(),
                Value<bool> autoExecute = const Value.absent(),
                Value<DateTime> createdAt = const Value.absent(),
                Value<DateTime?> lastUsedAt = const Value.absent(),
                Value<int> usageCount = const Value.absent(),
                Value<int> sortOrder = const Value.absent(),
              }) => SnippetsCompanion.insert(
                id: id,
                name: name,
                command: command,
                description: description,
                folderId: folderId,
                autoExecute: autoExecute,
                createdAt: createdAt,
                lastUsedAt: lastUsedAt,
                usageCount: usageCount,
                sortOrder: sortOrder,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$SnippetsTable, Snippet>(table),
                  $$SnippetsTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({folderId = false, hostsRefs = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [if (hostsRefs) db.hosts],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (folderId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.folderId,
                                referencedTable: $$SnippetsTableReferences
                                    ._folderIdTable(db),
                                referencedColumn: $$SnippetsTableReferences
                                    ._folderIdTable(db)
                                    .id,
                              )
                              as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [
                  if (hostsRefs)
                    await $_getPrefetchedData<Snippet, $SnippetsTable, Host>(
                      currentTable: table,
                      referencedTable: $$SnippetsTableReferences
                          ._hostsRefsTable(db),
                      managerFromTypedResult: (p0) =>
                          $$SnippetsTableReferences(db, table, p0).hostsRefs,
                      referencedItemsForCurrentItem: (item, referencedItems) =>
                          referencedItems.where(
                            (e) => e.autoConnectSnippetId == item.id,
                          ),
                      typedResults: items,
                    ),
                ];
              },
            );
          },
        ),
      );
}

typedef $$SnippetsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $SnippetsTable,
      Snippet,
      $$SnippetsTableFilterComposer,
      $$SnippetsTableOrderingComposer,
      $$SnippetsTableAnnotationComposer,
      $$SnippetsTableCreateCompanionBuilder,
      $$SnippetsTableUpdateCompanionBuilder,
      (Snippet, $$SnippetsTableReferences),
      Snippet,
      PrefetchHooks Function({bool folderId, bool hostsRefs})
    >;
typedef $$HostsTableCreateCompanionBuilder =
    HostsCompanion Function({
      Value<int> id,
      required String label,
      required String hostname,
      Value<int> port,
      required String username,
      Value<String?> password,
      Value<int?> keyId,
      Value<int?> groupId,
      Value<int?> jumpHostId,
      Value<String?> skipJumpHostOnSsids,
      Value<bool> isFavorite,
      Value<String?> color,
      Value<String?> notes,
      Value<String?> tags,
      Value<DateTime> createdAt,
      Value<DateTime> updatedAt,
      Value<DateTime?> lastConnectedAt,
      Value<String?> terminalThemeLightId,
      Value<String?> terminalThemeDarkId,
      Value<String?> terminalFontFamily,
      Value<String?> autoConnectCommand,
      Value<int?> autoConnectSnippetId,
      Value<bool> autoConnectRequiresConfirmation,
      Value<String?> tmuxSessionName,
      Value<String?> tmuxWorkingDirectory,
      Value<String?> tmuxExtraFlags,
      Value<String?> remoteMuxBackend,
      Value<bool> autoForwardPorts,
      Value<String?> portProxyName,
      Value<int> sortOrder,
    });
typedef $$HostsTableUpdateCompanionBuilder =
    HostsCompanion Function({
      Value<int> id,
      Value<String> label,
      Value<String> hostname,
      Value<int> port,
      Value<String> username,
      Value<String?> password,
      Value<int?> keyId,
      Value<int?> groupId,
      Value<int?> jumpHostId,
      Value<String?> skipJumpHostOnSsids,
      Value<bool> isFavorite,
      Value<String?> color,
      Value<String?> notes,
      Value<String?> tags,
      Value<DateTime> createdAt,
      Value<DateTime> updatedAt,
      Value<DateTime?> lastConnectedAt,
      Value<String?> terminalThemeLightId,
      Value<String?> terminalThemeDarkId,
      Value<String?> terminalFontFamily,
      Value<String?> autoConnectCommand,
      Value<int?> autoConnectSnippetId,
      Value<bool> autoConnectRequiresConfirmation,
      Value<String?> tmuxSessionName,
      Value<String?> tmuxWorkingDirectory,
      Value<String?> tmuxExtraFlags,
      Value<String?> remoteMuxBackend,
      Value<bool> autoForwardPorts,
      Value<String?> portProxyName,
      Value<int> sortOrder,
    });

final class $$HostsTableReferences
    extends BaseReferences<_$AppDatabase, $HostsTable, Host> {
  $$HostsTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $SshKeysTable _keyIdTable(_$AppDatabase db) =>
      db.sshKeys.createAlias('hosts__key_id__ssh_keys__id');

  $$SshKeysTableProcessedTableManager? get keyId {
    final $_column = $_itemColumn<int>('key_id');
    if ($_column == null) return null;
    final manager = $$SshKeysTableTableManager(
      $_db,
      $_db.sshKeys,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_keyIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }

  static $GroupsTable _groupIdTable(_$AppDatabase db) =>
      db.groups.createAlias('hosts__group_id__groups__id');

  $$GroupsTableProcessedTableManager? get groupId {
    final $_column = $_itemColumn<int>('group_id');
    if ($_column == null) return null;
    final manager = $$GroupsTableTableManager(
      $_db,
      $_db.groups,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_groupIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }

  static $HostsTable _jumpHostIdTable(_$AppDatabase db) =>
      db.hosts.createAlias('hosts__jump_host_id__hosts__id');

  $$HostsTableProcessedTableManager? get jumpHostId {
    final $_column = $_itemColumn<int>('jump_host_id');
    if ($_column == null) return null;
    final manager = $$HostsTableTableManager(
      $_db,
      $_db.hosts,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_jumpHostIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }

  static $SnippetsTable _autoConnectSnippetIdTable(_$AppDatabase db) =>
      db.snippets.createAlias('hosts__auto_connect_snippet_id__snippets__id');

  $$SnippetsTableProcessedTableManager? get autoConnectSnippetId {
    final $_column = $_itemColumn<int>('auto_connect_snippet_id');
    if ($_column == null) return null;
    final manager = $$SnippetsTableTableManager(
      $_db,
      $_db.snippets,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(
      _autoConnectSnippetIdTable($_db),
    );
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }

  static MultiTypedResultKey<$PortForwardsTable, List<PortForward>>
  _portForwardsRefsTable(_$AppDatabase db) => MultiTypedResultKey.fromTable(
    db.portForwards,
    aliasName: 'hosts__id__port_forwards__host_id',
  );

  $$PortForwardsTableProcessedTableManager get portForwardsRefs {
    final manager = $$PortForwardsTableTableManager(
      $_db,
      $_db.portForwards,
    ).filter((f) => f.hostId.id.sqlEquals($_itemColumn<int>('id')!));

    final cache = $_typedResult.readTableOrNull(_portForwardsRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }
}

class $$HostsTableFilterComposer extends Composer<_$AppDatabase, $HostsTable> {
  $$HostsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get label => $composableBuilder(
    column: $table.label,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get hostname => $composableBuilder(
    column: $table.hostname,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get port => $composableBuilder(
    column: $table.port,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get username => $composableBuilder(
    column: $table.username,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get password => $composableBuilder(
    column: $table.password,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get skipJumpHostOnSsids => $composableBuilder(
    column: $table.skipJumpHostOnSsids,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get isFavorite => $composableBuilder(
    column: $table.isFavorite,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get color => $composableBuilder(
    column: $table.color,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get notes => $composableBuilder(
    column: $table.notes,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get tags => $composableBuilder(
    column: $table.tags,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get lastConnectedAt => $composableBuilder(
    column: $table.lastConnectedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get terminalThemeLightId => $composableBuilder(
    column: $table.terminalThemeLightId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get terminalThemeDarkId => $composableBuilder(
    column: $table.terminalThemeDarkId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get terminalFontFamily => $composableBuilder(
    column: $table.terminalFontFamily,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get autoConnectCommand => $composableBuilder(
    column: $table.autoConnectCommand,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get autoConnectRequiresConfirmation => $composableBuilder(
    column: $table.autoConnectRequiresConfirmation,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get tmuxSessionName => $composableBuilder(
    column: $table.tmuxSessionName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get tmuxWorkingDirectory => $composableBuilder(
    column: $table.tmuxWorkingDirectory,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get tmuxExtraFlags => $composableBuilder(
    column: $table.tmuxExtraFlags,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get remoteMuxBackend => $composableBuilder(
    column: $table.remoteMuxBackend,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get autoForwardPorts => $composableBuilder(
    column: $table.autoForwardPorts,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get portProxyName => $composableBuilder(
    column: $table.portProxyName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get sortOrder => $composableBuilder(
    column: $table.sortOrder,
    builder: (column) => ColumnFilters(column),
  );

  $$SshKeysTableFilterComposer get keyId {
    final $$SshKeysTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.keyId,
      referencedTable: $db.sshKeys,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$SshKeysTableFilterComposer(
            $db: $db,
            $table: $db.sshKeys,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$GroupsTableFilterComposer get groupId {
    final $$GroupsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.groupId,
      referencedTable: $db.groups,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$GroupsTableFilterComposer(
            $db: $db,
            $table: $db.groups,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$HostsTableFilterComposer get jumpHostId {
    final $$HostsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.jumpHostId,
      referencedTable: $db.hosts,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$HostsTableFilterComposer(
            $db: $db,
            $table: $db.hosts,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$SnippetsTableFilterComposer get autoConnectSnippetId {
    final $$SnippetsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.autoConnectSnippetId,
      referencedTable: $db.snippets,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$SnippetsTableFilterComposer(
            $db: $db,
            $table: $db.snippets,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  Expression<bool> portForwardsRefs(
    Expression<bool> Function($$PortForwardsTableFilterComposer f) f,
  ) {
    final $$PortForwardsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.portForwards,
      getReferencedColumn: (t) => t.hostId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$PortForwardsTableFilterComposer(
            $db: $db,
            $table: $db.portForwards,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$HostsTableOrderingComposer
    extends Composer<_$AppDatabase, $HostsTable> {
  $$HostsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get label => $composableBuilder(
    column: $table.label,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get hostname => $composableBuilder(
    column: $table.hostname,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get port => $composableBuilder(
    column: $table.port,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get username => $composableBuilder(
    column: $table.username,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get password => $composableBuilder(
    column: $table.password,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get skipJumpHostOnSsids => $composableBuilder(
    column: $table.skipJumpHostOnSsids,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get isFavorite => $composableBuilder(
    column: $table.isFavorite,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get color => $composableBuilder(
    column: $table.color,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get notes => $composableBuilder(
    column: $table.notes,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get tags => $composableBuilder(
    column: $table.tags,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get lastConnectedAt => $composableBuilder(
    column: $table.lastConnectedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get terminalThemeLightId => $composableBuilder(
    column: $table.terminalThemeLightId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get terminalThemeDarkId => $composableBuilder(
    column: $table.terminalThemeDarkId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get terminalFontFamily => $composableBuilder(
    column: $table.terminalFontFamily,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get autoConnectCommand => $composableBuilder(
    column: $table.autoConnectCommand,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get autoConnectRequiresConfirmation =>
      $composableBuilder(
        column: $table.autoConnectRequiresConfirmation,
        builder: (column) => ColumnOrderings(column),
      );

  ColumnOrderings<String> get tmuxSessionName => $composableBuilder(
    column: $table.tmuxSessionName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get tmuxWorkingDirectory => $composableBuilder(
    column: $table.tmuxWorkingDirectory,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get tmuxExtraFlags => $composableBuilder(
    column: $table.tmuxExtraFlags,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get remoteMuxBackend => $composableBuilder(
    column: $table.remoteMuxBackend,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get autoForwardPorts => $composableBuilder(
    column: $table.autoForwardPorts,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get portProxyName => $composableBuilder(
    column: $table.portProxyName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get sortOrder => $composableBuilder(
    column: $table.sortOrder,
    builder: (column) => ColumnOrderings(column),
  );

  $$SshKeysTableOrderingComposer get keyId {
    final $$SshKeysTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.keyId,
      referencedTable: $db.sshKeys,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$SshKeysTableOrderingComposer(
            $db: $db,
            $table: $db.sshKeys,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$GroupsTableOrderingComposer get groupId {
    final $$GroupsTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.groupId,
      referencedTable: $db.groups,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$GroupsTableOrderingComposer(
            $db: $db,
            $table: $db.groups,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$HostsTableOrderingComposer get jumpHostId {
    final $$HostsTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.jumpHostId,
      referencedTable: $db.hosts,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$HostsTableOrderingComposer(
            $db: $db,
            $table: $db.hosts,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$SnippetsTableOrderingComposer get autoConnectSnippetId {
    final $$SnippetsTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.autoConnectSnippetId,
      referencedTable: $db.snippets,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$SnippetsTableOrderingComposer(
            $db: $db,
            $table: $db.snippets,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$HostsTableAnnotationComposer
    extends Composer<_$AppDatabase, $HostsTable> {
  $$HostsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get label =>
      $composableBuilder(column: $table.label, builder: (column) => column);

  GeneratedColumn<String> get hostname =>
      $composableBuilder(column: $table.hostname, builder: (column) => column);

  GeneratedColumn<int> get port =>
      $composableBuilder(column: $table.port, builder: (column) => column);

  GeneratedColumn<String> get username =>
      $composableBuilder(column: $table.username, builder: (column) => column);

  GeneratedColumn<String> get password =>
      $composableBuilder(column: $table.password, builder: (column) => column);

  GeneratedColumn<String> get skipJumpHostOnSsids => $composableBuilder(
    column: $table.skipJumpHostOnSsids,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get isFavorite => $composableBuilder(
    column: $table.isFavorite,
    builder: (column) => column,
  );

  GeneratedColumn<String> get color =>
      $composableBuilder(column: $table.color, builder: (column) => column);

  GeneratedColumn<String> get notes =>
      $composableBuilder(column: $table.notes, builder: (column) => column);

  GeneratedColumn<String> get tags =>
      $composableBuilder(column: $table.tags, builder: (column) => column);

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  GeneratedColumn<DateTime> get lastConnectedAt => $composableBuilder(
    column: $table.lastConnectedAt,
    builder: (column) => column,
  );

  GeneratedColumn<String> get terminalThemeLightId => $composableBuilder(
    column: $table.terminalThemeLightId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get terminalThemeDarkId => $composableBuilder(
    column: $table.terminalThemeDarkId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get terminalFontFamily => $composableBuilder(
    column: $table.terminalFontFamily,
    builder: (column) => column,
  );

  GeneratedColumn<String> get autoConnectCommand => $composableBuilder(
    column: $table.autoConnectCommand,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get autoConnectRequiresConfirmation =>
      $composableBuilder(
        column: $table.autoConnectRequiresConfirmation,
        builder: (column) => column,
      );

  GeneratedColumn<String> get tmuxSessionName => $composableBuilder(
    column: $table.tmuxSessionName,
    builder: (column) => column,
  );

  GeneratedColumn<String> get tmuxWorkingDirectory => $composableBuilder(
    column: $table.tmuxWorkingDirectory,
    builder: (column) => column,
  );

  GeneratedColumn<String> get tmuxExtraFlags => $composableBuilder(
    column: $table.tmuxExtraFlags,
    builder: (column) => column,
  );

  GeneratedColumn<String> get remoteMuxBackend => $composableBuilder(
    column: $table.remoteMuxBackend,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get autoForwardPorts => $composableBuilder(
    column: $table.autoForwardPorts,
    builder: (column) => column,
  );

  GeneratedColumn<String> get portProxyName => $composableBuilder(
    column: $table.portProxyName,
    builder: (column) => column,
  );

  GeneratedColumn<int> get sortOrder =>
      $composableBuilder(column: $table.sortOrder, builder: (column) => column);

  $$SshKeysTableAnnotationComposer get keyId {
    final $$SshKeysTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.keyId,
      referencedTable: $db.sshKeys,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$SshKeysTableAnnotationComposer(
            $db: $db,
            $table: $db.sshKeys,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$GroupsTableAnnotationComposer get groupId {
    final $$GroupsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.groupId,
      referencedTable: $db.groups,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$GroupsTableAnnotationComposer(
            $db: $db,
            $table: $db.groups,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$HostsTableAnnotationComposer get jumpHostId {
    final $$HostsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.jumpHostId,
      referencedTable: $db.hosts,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$HostsTableAnnotationComposer(
            $db: $db,
            $table: $db.hosts,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$SnippetsTableAnnotationComposer get autoConnectSnippetId {
    final $$SnippetsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.autoConnectSnippetId,
      referencedTable: $db.snippets,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$SnippetsTableAnnotationComposer(
            $db: $db,
            $table: $db.snippets,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  Expression<T> portForwardsRefs<T extends Object>(
    Expression<T> Function($$PortForwardsTableAnnotationComposer a) f,
  ) {
    final $$PortForwardsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.portForwards,
      getReferencedColumn: (t) => t.hostId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$PortForwardsTableAnnotationComposer(
            $db: $db,
            $table: $db.portForwards,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$HostsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $HostsTable,
          Host,
          $$HostsTableFilterComposer,
          $$HostsTableOrderingComposer,
          $$HostsTableAnnotationComposer,
          $$HostsTableCreateCompanionBuilder,
          $$HostsTableUpdateCompanionBuilder,
          (Host, $$HostsTableReferences),
          Host,
          PrefetchHooks Function({
            bool keyId,
            bool groupId,
            bool jumpHostId,
            bool autoConnectSnippetId,
            bool portForwardsRefs,
          })
        > {
  $$HostsTableTableManager(_$AppDatabase db, $HostsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$HostsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$HostsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$HostsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<String> label = const Value.absent(),
                Value<String> hostname = const Value.absent(),
                Value<int> port = const Value.absent(),
                Value<String> username = const Value.absent(),
                Value<String?> password = const Value.absent(),
                Value<int?> keyId = const Value.absent(),
                Value<int?> groupId = const Value.absent(),
                Value<int?> jumpHostId = const Value.absent(),
                Value<String?> skipJumpHostOnSsids = const Value.absent(),
                Value<bool> isFavorite = const Value.absent(),
                Value<String?> color = const Value.absent(),
                Value<String?> notes = const Value.absent(),
                Value<String?> tags = const Value.absent(),
                Value<DateTime> createdAt = const Value.absent(),
                Value<DateTime> updatedAt = const Value.absent(),
                Value<DateTime?> lastConnectedAt = const Value.absent(),
                Value<String?> terminalThemeLightId = const Value.absent(),
                Value<String?> terminalThemeDarkId = const Value.absent(),
                Value<String?> terminalFontFamily = const Value.absent(),
                Value<String?> autoConnectCommand = const Value.absent(),
                Value<int?> autoConnectSnippetId = const Value.absent(),
                Value<bool> autoConnectRequiresConfirmation =
                    const Value.absent(),
                Value<String?> tmuxSessionName = const Value.absent(),
                Value<String?> tmuxWorkingDirectory = const Value.absent(),
                Value<String?> tmuxExtraFlags = const Value.absent(),
                Value<String?> remoteMuxBackend = const Value.absent(),
                Value<bool> autoForwardPorts = const Value.absent(),
                Value<String?> portProxyName = const Value.absent(),
                Value<int> sortOrder = const Value.absent(),
              }) => HostsCompanion(
                id: id,
                label: label,
                hostname: hostname,
                port: port,
                username: username,
                password: password,
                keyId: keyId,
                groupId: groupId,
                jumpHostId: jumpHostId,
                skipJumpHostOnSsids: skipJumpHostOnSsids,
                isFavorite: isFavorite,
                color: color,
                notes: notes,
                tags: tags,
                createdAt: createdAt,
                updatedAt: updatedAt,
                lastConnectedAt: lastConnectedAt,
                terminalThemeLightId: terminalThemeLightId,
                terminalThemeDarkId: terminalThemeDarkId,
                terminalFontFamily: terminalFontFamily,
                autoConnectCommand: autoConnectCommand,
                autoConnectSnippetId: autoConnectSnippetId,
                autoConnectRequiresConfirmation:
                    autoConnectRequiresConfirmation,
                tmuxSessionName: tmuxSessionName,
                tmuxWorkingDirectory: tmuxWorkingDirectory,
                tmuxExtraFlags: tmuxExtraFlags,
                remoteMuxBackend: remoteMuxBackend,
                autoForwardPorts: autoForwardPorts,
                portProxyName: portProxyName,
                sortOrder: sortOrder,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required String label,
                required String hostname,
                Value<int> port = const Value.absent(),
                required String username,
                Value<String?> password = const Value.absent(),
                Value<int?> keyId = const Value.absent(),
                Value<int?> groupId = const Value.absent(),
                Value<int?> jumpHostId = const Value.absent(),
                Value<String?> skipJumpHostOnSsids = const Value.absent(),
                Value<bool> isFavorite = const Value.absent(),
                Value<String?> color = const Value.absent(),
                Value<String?> notes = const Value.absent(),
                Value<String?> tags = const Value.absent(),
                Value<DateTime> createdAt = const Value.absent(),
                Value<DateTime> updatedAt = const Value.absent(),
                Value<DateTime?> lastConnectedAt = const Value.absent(),
                Value<String?> terminalThemeLightId = const Value.absent(),
                Value<String?> terminalThemeDarkId = const Value.absent(),
                Value<String?> terminalFontFamily = const Value.absent(),
                Value<String?> autoConnectCommand = const Value.absent(),
                Value<int?> autoConnectSnippetId = const Value.absent(),
                Value<bool> autoConnectRequiresConfirmation =
                    const Value.absent(),
                Value<String?> tmuxSessionName = const Value.absent(),
                Value<String?> tmuxWorkingDirectory = const Value.absent(),
                Value<String?> tmuxExtraFlags = const Value.absent(),
                Value<String?> remoteMuxBackend = const Value.absent(),
                Value<bool> autoForwardPorts = const Value.absent(),
                Value<String?> portProxyName = const Value.absent(),
                Value<int> sortOrder = const Value.absent(),
              }) => HostsCompanion.insert(
                id: id,
                label: label,
                hostname: hostname,
                port: port,
                username: username,
                password: password,
                keyId: keyId,
                groupId: groupId,
                jumpHostId: jumpHostId,
                skipJumpHostOnSsids: skipJumpHostOnSsids,
                isFavorite: isFavorite,
                color: color,
                notes: notes,
                tags: tags,
                createdAt: createdAt,
                updatedAt: updatedAt,
                lastConnectedAt: lastConnectedAt,
                terminalThemeLightId: terminalThemeLightId,
                terminalThemeDarkId: terminalThemeDarkId,
                terminalFontFamily: terminalFontFamily,
                autoConnectCommand: autoConnectCommand,
                autoConnectSnippetId: autoConnectSnippetId,
                autoConnectRequiresConfirmation:
                    autoConnectRequiresConfirmation,
                tmuxSessionName: tmuxSessionName,
                tmuxWorkingDirectory: tmuxWorkingDirectory,
                tmuxExtraFlags: tmuxExtraFlags,
                remoteMuxBackend: remoteMuxBackend,
                autoForwardPorts: autoForwardPorts,
                portProxyName: portProxyName,
                sortOrder: sortOrder,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$HostsTable, Host>(table),
                  $$HostsTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback:
              ({
                keyId = false,
                groupId = false,
                jumpHostId = false,
                autoConnectSnippetId = false,
                portForwardsRefs = false,
              }) {
                return PrefetchHooks(
                  db: db,
                  explicitlyWatchedTables: [
                    if (portForwardsRefs) db.portForwards,
                  ],
                  addJoins:
                      <
                        T extends TableManagerState<
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic
                        >
                      >(state) {
                        if (keyId) {
                          state =
                              state.withJoin(
                                    currentTable: table,
                                    currentColumn: table.keyId,
                                    referencedTable: $$HostsTableReferences
                                        ._keyIdTable(db),
                                    referencedColumn: $$HostsTableReferences
                                        ._keyIdTable(db)
                                        .id,
                                  )
                                  as T;
                        }
                        if (groupId) {
                          state =
                              state.withJoin(
                                    currentTable: table,
                                    currentColumn: table.groupId,
                                    referencedTable: $$HostsTableReferences
                                        ._groupIdTable(db),
                                    referencedColumn: $$HostsTableReferences
                                        ._groupIdTable(db)
                                        .id,
                                  )
                                  as T;
                        }
                        if (jumpHostId) {
                          state =
                              state.withJoin(
                                    currentTable: table,
                                    currentColumn: table.jumpHostId,
                                    referencedTable: $$HostsTableReferences
                                        ._jumpHostIdTable(db),
                                    referencedColumn: $$HostsTableReferences
                                        ._jumpHostIdTable(db)
                                        .id,
                                  )
                                  as T;
                        }
                        if (autoConnectSnippetId) {
                          state =
                              state.withJoin(
                                    currentTable: table,
                                    currentColumn: table.autoConnectSnippetId,
                                    referencedTable: $$HostsTableReferences
                                        ._autoConnectSnippetIdTable(db),
                                    referencedColumn: $$HostsTableReferences
                                        ._autoConnectSnippetIdTable(db)
                                        .id,
                                  )
                                  as T;
                        }

                        return state;
                      },
                  getPrefetchedDataCallback: (items) async {
                    return [
                      if (portForwardsRefs)
                        await $_getPrefetchedData<
                          Host,
                          $HostsTable,
                          PortForward
                        >(
                          currentTable: table,
                          referencedTable: $$HostsTableReferences
                              ._portForwardsRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$HostsTableReferences(
                                db,
                                table,
                                p0,
                              ).portForwardsRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.hostId == item.id,
                              ),
                          typedResults: items,
                        ),
                    ];
                  },
                );
              },
        ),
      );
}

typedef $$HostsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $HostsTable,
      Host,
      $$HostsTableFilterComposer,
      $$HostsTableOrderingComposer,
      $$HostsTableAnnotationComposer,
      $$HostsTableCreateCompanionBuilder,
      $$HostsTableUpdateCompanionBuilder,
      (Host, $$HostsTableReferences),
      Host,
      PrefetchHooks Function({
        bool keyId,
        bool groupId,
        bool jumpHostId,
        bool autoConnectSnippetId,
        bool portForwardsRefs,
      })
    >;
typedef $$PortForwardsTableCreateCompanionBuilder =
    PortForwardsCompanion Function({
      Value<int> id,
      required String name,
      required int hostId,
      required String forwardType,
      Value<String> localHost,
      required int localPort,
      required String remoteHost,
      required int remotePort,
      Value<bool> autoStart,
      Value<DateTime> createdAt,
    });
typedef $$PortForwardsTableUpdateCompanionBuilder =
    PortForwardsCompanion Function({
      Value<int> id,
      Value<String> name,
      Value<int> hostId,
      Value<String> forwardType,
      Value<String> localHost,
      Value<int> localPort,
      Value<String> remoteHost,
      Value<int> remotePort,
      Value<bool> autoStart,
      Value<DateTime> createdAt,
    });

final class $$PortForwardsTableReferences
    extends BaseReferences<_$AppDatabase, $PortForwardsTable, PortForward> {
  $$PortForwardsTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $HostsTable _hostIdTable(_$AppDatabase db) =>
      db.hosts.createAlias('port_forwards__host_id__hosts__id');

  $$HostsTableProcessedTableManager get hostId {
    final $_column = $_itemColumn<int>('host_id')!;

    final manager = $$HostsTableTableManager(
      $_db,
      $_db.hosts,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_hostIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$PortForwardsTableFilterComposer
    extends Composer<_$AppDatabase, $PortForwardsTable> {
  $$PortForwardsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get forwardType => $composableBuilder(
    column: $table.forwardType,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get localHost => $composableBuilder(
    column: $table.localHost,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get localPort => $composableBuilder(
    column: $table.localPort,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get remoteHost => $composableBuilder(
    column: $table.remoteHost,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get remotePort => $composableBuilder(
    column: $table.remotePort,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get autoStart => $composableBuilder(
    column: $table.autoStart,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  $$HostsTableFilterComposer get hostId {
    final $$HostsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.hostId,
      referencedTable: $db.hosts,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$HostsTableFilterComposer(
            $db: $db,
            $table: $db.hosts,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$PortForwardsTableOrderingComposer
    extends Composer<_$AppDatabase, $PortForwardsTable> {
  $$PortForwardsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get forwardType => $composableBuilder(
    column: $table.forwardType,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get localHost => $composableBuilder(
    column: $table.localHost,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get localPort => $composableBuilder(
    column: $table.localPort,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get remoteHost => $composableBuilder(
    column: $table.remoteHost,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get remotePort => $composableBuilder(
    column: $table.remotePort,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get autoStart => $composableBuilder(
    column: $table.autoStart,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  $$HostsTableOrderingComposer get hostId {
    final $$HostsTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.hostId,
      referencedTable: $db.hosts,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$HostsTableOrderingComposer(
            $db: $db,
            $table: $db.hosts,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$PortForwardsTableAnnotationComposer
    extends Composer<_$AppDatabase, $PortForwardsTable> {
  $$PortForwardsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<String> get forwardType => $composableBuilder(
    column: $table.forwardType,
    builder: (column) => column,
  );

  GeneratedColumn<String> get localHost =>
      $composableBuilder(column: $table.localHost, builder: (column) => column);

  GeneratedColumn<int> get localPort =>
      $composableBuilder(column: $table.localPort, builder: (column) => column);

  GeneratedColumn<String> get remoteHost => $composableBuilder(
    column: $table.remoteHost,
    builder: (column) => column,
  );

  GeneratedColumn<int> get remotePort => $composableBuilder(
    column: $table.remotePort,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get autoStart =>
      $composableBuilder(column: $table.autoStart, builder: (column) => column);

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  $$HostsTableAnnotationComposer get hostId {
    final $$HostsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.hostId,
      referencedTable: $db.hosts,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$HostsTableAnnotationComposer(
            $db: $db,
            $table: $db.hosts,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$PortForwardsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $PortForwardsTable,
          PortForward,
          $$PortForwardsTableFilterComposer,
          $$PortForwardsTableOrderingComposer,
          $$PortForwardsTableAnnotationComposer,
          $$PortForwardsTableCreateCompanionBuilder,
          $$PortForwardsTableUpdateCompanionBuilder,
          (PortForward, $$PortForwardsTableReferences),
          PortForward,
          PrefetchHooks Function({bool hostId})
        > {
  $$PortForwardsTableTableManager(_$AppDatabase db, $PortForwardsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$PortForwardsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$PortForwardsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$PortForwardsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<int> hostId = const Value.absent(),
                Value<String> forwardType = const Value.absent(),
                Value<String> localHost = const Value.absent(),
                Value<int> localPort = const Value.absent(),
                Value<String> remoteHost = const Value.absent(),
                Value<int> remotePort = const Value.absent(),
                Value<bool> autoStart = const Value.absent(),
                Value<DateTime> createdAt = const Value.absent(),
              }) => PortForwardsCompanion(
                id: id,
                name: name,
                hostId: hostId,
                forwardType: forwardType,
                localHost: localHost,
                localPort: localPort,
                remoteHost: remoteHost,
                remotePort: remotePort,
                autoStart: autoStart,
                createdAt: createdAt,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required String name,
                required int hostId,
                required String forwardType,
                Value<String> localHost = const Value.absent(),
                required int localPort,
                required String remoteHost,
                required int remotePort,
                Value<bool> autoStart = const Value.absent(),
                Value<DateTime> createdAt = const Value.absent(),
              }) => PortForwardsCompanion.insert(
                id: id,
                name: name,
                hostId: hostId,
                forwardType: forwardType,
                localHost: localHost,
                localPort: localPort,
                remoteHost: remoteHost,
                remotePort: remotePort,
                autoStart: autoStart,
                createdAt: createdAt,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$PortForwardsTable, PortForward>(table),
                  $$PortForwardsTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({hostId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (hostId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.hostId,
                                referencedTable: $$PortForwardsTableReferences
                                    ._hostIdTable(db),
                                referencedColumn: $$PortForwardsTableReferences
                                    ._hostIdTable(db)
                                    .id,
                              )
                              as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $$PortForwardsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $PortForwardsTable,
      PortForward,
      $$PortForwardsTableFilterComposer,
      $$PortForwardsTableOrderingComposer,
      $$PortForwardsTableAnnotationComposer,
      $$PortForwardsTableCreateCompanionBuilder,
      $$PortForwardsTableUpdateCompanionBuilder,
      (PortForward, $$PortForwardsTableReferences),
      PortForward,
      PrefetchHooks Function({bool hostId})
    >;
typedef $$KnownHostsTableCreateCompanionBuilder =
    KnownHostsCompanion Function({
      Value<int> id,
      required String hostname,
      required int port,
      required String keyType,
      required String fingerprint,
      required String hostKey,
      Value<DateTime> firstSeen,
      Value<DateTime> lastSeen,
    });
typedef $$KnownHostsTableUpdateCompanionBuilder =
    KnownHostsCompanion Function({
      Value<int> id,
      Value<String> hostname,
      Value<int> port,
      Value<String> keyType,
      Value<String> fingerprint,
      Value<String> hostKey,
      Value<DateTime> firstSeen,
      Value<DateTime> lastSeen,
    });

class $$KnownHostsTableFilterComposer
    extends Composer<_$AppDatabase, $KnownHostsTable> {
  $$KnownHostsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get hostname => $composableBuilder(
    column: $table.hostname,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get port => $composableBuilder(
    column: $table.port,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get keyType => $composableBuilder(
    column: $table.keyType,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get fingerprint => $composableBuilder(
    column: $table.fingerprint,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get hostKey => $composableBuilder(
    column: $table.hostKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get firstSeen => $composableBuilder(
    column: $table.firstSeen,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get lastSeen => $composableBuilder(
    column: $table.lastSeen,
    builder: (column) => ColumnFilters(column),
  );
}

class $$KnownHostsTableOrderingComposer
    extends Composer<_$AppDatabase, $KnownHostsTable> {
  $$KnownHostsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get hostname => $composableBuilder(
    column: $table.hostname,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get port => $composableBuilder(
    column: $table.port,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get keyType => $composableBuilder(
    column: $table.keyType,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get fingerprint => $composableBuilder(
    column: $table.fingerprint,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get hostKey => $composableBuilder(
    column: $table.hostKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get firstSeen => $composableBuilder(
    column: $table.firstSeen,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get lastSeen => $composableBuilder(
    column: $table.lastSeen,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$KnownHostsTableAnnotationComposer
    extends Composer<_$AppDatabase, $KnownHostsTable> {
  $$KnownHostsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get hostname =>
      $composableBuilder(column: $table.hostname, builder: (column) => column);

  GeneratedColumn<int> get port =>
      $composableBuilder(column: $table.port, builder: (column) => column);

  GeneratedColumn<String> get keyType =>
      $composableBuilder(column: $table.keyType, builder: (column) => column);

  GeneratedColumn<String> get fingerprint => $composableBuilder(
    column: $table.fingerprint,
    builder: (column) => column,
  );

  GeneratedColumn<String> get hostKey =>
      $composableBuilder(column: $table.hostKey, builder: (column) => column);

  GeneratedColumn<DateTime> get firstSeen =>
      $composableBuilder(column: $table.firstSeen, builder: (column) => column);

  GeneratedColumn<DateTime> get lastSeen =>
      $composableBuilder(column: $table.lastSeen, builder: (column) => column);
}

class $$KnownHostsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $KnownHostsTable,
          KnownHost,
          $$KnownHostsTableFilterComposer,
          $$KnownHostsTableOrderingComposer,
          $$KnownHostsTableAnnotationComposer,
          $$KnownHostsTableCreateCompanionBuilder,
          $$KnownHostsTableUpdateCompanionBuilder,
          (
            KnownHost,
            BaseReferences<_$AppDatabase, $KnownHostsTable, KnownHost>,
          ),
          KnownHost,
          PrefetchHooks Function()
        > {
  $$KnownHostsTableTableManager(_$AppDatabase db, $KnownHostsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$KnownHostsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$KnownHostsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$KnownHostsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<String> hostname = const Value.absent(),
                Value<int> port = const Value.absent(),
                Value<String> keyType = const Value.absent(),
                Value<String> fingerprint = const Value.absent(),
                Value<String> hostKey = const Value.absent(),
                Value<DateTime> firstSeen = const Value.absent(),
                Value<DateTime> lastSeen = const Value.absent(),
              }) => KnownHostsCompanion(
                id: id,
                hostname: hostname,
                port: port,
                keyType: keyType,
                fingerprint: fingerprint,
                hostKey: hostKey,
                firstSeen: firstSeen,
                lastSeen: lastSeen,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required String hostname,
                required int port,
                required String keyType,
                required String fingerprint,
                required String hostKey,
                Value<DateTime> firstSeen = const Value.absent(),
                Value<DateTime> lastSeen = const Value.absent(),
              }) => KnownHostsCompanion.insert(
                id: id,
                hostname: hostname,
                port: port,
                keyType: keyType,
                fingerprint: fingerprint,
                hostKey: hostKey,
                firstSeen: firstSeen,
                lastSeen: lastSeen,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$KnownHostsTable, KnownHost>(table),
                  BaseReferences<_$AppDatabase, $KnownHostsTable, KnownHost>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$KnownHostsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $KnownHostsTable,
      KnownHost,
      $$KnownHostsTableFilterComposer,
      $$KnownHostsTableOrderingComposer,
      $$KnownHostsTableAnnotationComposer,
      $$KnownHostsTableCreateCompanionBuilder,
      $$KnownHostsTableUpdateCompanionBuilder,
      (KnownHost, BaseReferences<_$AppDatabase, $KnownHostsTable, KnownHost>),
      KnownHost,
      PrefetchHooks Function()
    >;
typedef $$SettingsTableCreateCompanionBuilder =
    SettingsCompanion Function({
      required String key,
      required String value,
      Value<int> rowid,
    });
typedef $$SettingsTableUpdateCompanionBuilder =
    SettingsCompanion Function({
      Value<String> key,
      Value<String> value,
      Value<int> rowid,
    });

class $$SettingsTableFilterComposer
    extends Composer<_$AppDatabase, $SettingsTable> {
  $$SettingsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get key => $composableBuilder(
    column: $table.key,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get value => $composableBuilder(
    column: $table.value,
    builder: (column) => ColumnFilters(column),
  );
}

class $$SettingsTableOrderingComposer
    extends Composer<_$AppDatabase, $SettingsTable> {
  $$SettingsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get key => $composableBuilder(
    column: $table.key,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get value => $composableBuilder(
    column: $table.value,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$SettingsTableAnnotationComposer
    extends Composer<_$AppDatabase, $SettingsTable> {
  $$SettingsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get key =>
      $composableBuilder(column: $table.key, builder: (column) => column);

  GeneratedColumn<String> get value =>
      $composableBuilder(column: $table.value, builder: (column) => column);
}

class $$SettingsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $SettingsTable,
          Setting,
          $$SettingsTableFilterComposer,
          $$SettingsTableOrderingComposer,
          $$SettingsTableAnnotationComposer,
          $$SettingsTableCreateCompanionBuilder,
          $$SettingsTableUpdateCompanionBuilder,
          (Setting, BaseReferences<_$AppDatabase, $SettingsTable, Setting>),
          Setting,
          PrefetchHooks Function()
        > {
  $$SettingsTableTableManager(_$AppDatabase db, $SettingsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SettingsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SettingsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SettingsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> key = const Value.absent(),
                Value<String> value = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SettingsCompanion(key: key, value: value, rowid: rowid),
          createCompanionCallback:
              ({
                required String key,
                required String value,
                Value<int> rowid = const Value.absent(),
              }) => SettingsCompanion.insert(
                key: key,
                value: value,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$SettingsTable, Setting>(table),
                  BaseReferences<_$AppDatabase, $SettingsTable, Setting>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$SettingsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $SettingsTable,
      Setting,
      $$SettingsTableFilterComposer,
      $$SettingsTableOrderingComposer,
      $$SettingsTableAnnotationComposer,
      $$SettingsTableCreateCompanionBuilder,
      $$SettingsTableUpdateCompanionBuilder,
      (Setting, BaseReferences<_$AppDatabase, $SettingsTable, Setting>),
      Setting,
      PrefetchHooks Function()
    >;

class $AppDatabaseManager {
  final _$AppDatabase _db;
  $AppDatabaseManager(this._db);
  $$SshKeysTableTableManager get sshKeys =>
      $$SshKeysTableTableManager(_db, _db.sshKeys);
  $$GroupsTableTableManager get groups =>
      $$GroupsTableTableManager(_db, _db.groups);
  $$SnippetFoldersTableTableManager get snippetFolders =>
      $$SnippetFoldersTableTableManager(_db, _db.snippetFolders);
  $$SnippetsTableTableManager get snippets =>
      $$SnippetsTableTableManager(_db, _db.snippets);
  $$HostsTableTableManager get hosts =>
      $$HostsTableTableManager(_db, _db.hosts);
  $$PortForwardsTableTableManager get portForwards =>
      $$PortForwardsTableTableManager(_db, _db.portForwards);
  $$KnownHostsTableTableManager get knownHosts =>
      $$KnownHostsTableTableManager(_db, _db.knownHosts);
  $$SettingsTableTableManager get settings =>
      $$SettingsTableTableManager(_db, _db.settings);
}
