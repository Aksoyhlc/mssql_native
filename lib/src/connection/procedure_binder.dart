import '../exception.dart';
import '../metadata_cache.dart';
import '../models/parameter.dart';
import '../models/types.dart';
import '../sql.dart';
import 'metadata_decoder.dart';

Map<String, MssqlTableRows> splitTableParameters(
  List<ProcedureParameterMetadata> metadata,
  Map<String, Object?> parameters,
) {
  final tableParameters = <String, ProcedureParameterMetadata>{
    for (final item in metadata)
      if (item.isTableType) item.name: item,
  };
  if (tableParameters.isEmpty) return const <String, MssqlTableRows>{};
  final tables = <String, MssqlTableRows>{};
  for (final entry in parameters.entries) {
    final name = normalizeParameterName(entry.key);
    if (!tableParameters.containsKey(name)) continue;
    final value = entry.value;
    if (value is MssqlTableRows) {
      tables[name] = value;
      continue;
    }
    if (value is Iterable<Map<String, Object?>>) {
      tables[name] = MssqlTableRows(value);
      continue;
    }
    throw ArgumentError.value(
      value,
      name,
      'Parameter "$name" is a table type. Pass MssqlTableRows or an '
      'Iterable<Map<String, Object?>>.',
    );
  }
  return tables;
}

void assertDeclaredIsFor({
  required MssqlMultipartIdentifier identifier,
  required MssqlProcedureMetadata declared,
}) {
  final MssqlMultipartIdentifier parsed;
  try {
    parsed = MssqlMultipartIdentifier.parse(declared.procedure);
  } on ArgumentError {
    throw MssqlException(
      type: MssqlErrorType.configuration,
      message:
          'MssqlProcedureMetadata.procedure is '
          '"${declared.procedure}", which is not a SQL identifier. It names '
          'the procedure the declaration describes, and is compared against '
          'the one being called.',
    );
  }
  // Compared on the trailing parts both names have, so `create_label`
  // matches `dbo.create_label` but `sales.create_label` does not.
  final a = identifier.parts;
  final b = parsed.parts;
  final shared = a.length < b.length ? a.length : b.length;
  for (var i = 1; i <= shared; i++) {
    if (a[a.length - i].toLowerCase() != b[b.length - i].toLowerCase()) {
      throw MssqlException(
        type: MssqlErrorType.configuration,
        message:
            'The declared metadata describes "${declared.procedure}", but '
            'this call is to "${identifier.quoted}". Passing one '
            'procedure\'s declaration to another binds its arguments with '
            'the wrong types, sizes and directions.',
      );
    }
  }
}

List<ProcedureParameterMetadata> procedureMetadataFromDeclared(
  MssqlProcedureMetadata declared,
) {
  return <ProcedureParameterMetadata>[
    for (final parameter in declared.parameters)
      ProcedureParameterMetadata(
        name: normalizeParameterName(parameter.name),
        type: parameter.type,
        size: parameter.size,
        precision: parameter.precision,
        scale: parameter.scale,
        isOutput: parameter.isOutput,
        isReadOnly: parameter.isReadOnly || parameter.tableTypeName != null,
        tableTypeName: parameter.tableTypeName,
        tableTypeSchema: parameter.tableTypeSchema,
      ),
  ];
}

void assertProcedureMetadata(
  MssqlProcedureMetadata declared,
  List<ProcedureParameterMetadata> live,
) {
  final expected = procedureMetadataFromDeclared(declared);
  if (expected.length != live.length) {
    throw MssqlException(
      type: MssqlErrorType.configuration,
      message:
          'Procedure "${declared.procedure}" has ${live.length} parameter(s) '
          'on the server and ${expected.length} in generated metadata. '
          'Regenerate against the live procedure, or pass '
          'driftPolicy: MssqlMetadataDriftPolicy.alwaysDescribe.',
    );
  }
  for (var i = 0; i < live.length; i++) {
    final a = expected[i];
    final b = live[i];
    if (a.name == b.name &&
        a.type == b.type &&
        a.size == b.size &&
        a.precision == b.precision &&
        a.scale == b.scale &&
        a.isOutput == b.isOutput &&
        a.tableTypeName == b.tableTypeName &&
        a.tableTypeSchema == b.tableTypeSchema) {
      continue;
    }
    throw MssqlException(
      type: MssqlErrorType.configuration,
      message:
          'Procedure "${declared.procedure}" parameter "${b.name}" does not '
          'match generated metadata. The server has ${b.type.name} '
          '(size ${b.size}, precision ${b.precision}, scale ${b.scale}); '
          'generation has ${a.type.name} (size ${a.size}, precision '
          '${a.precision}, scale ${a.scale}). Regenerate, or pass '
          'driftPolicy: MssqlMetadataDriftPolicy.alwaysDescribe.',
    );
  }
}

List<MssqlParameterBinding> compileProcedureParameters(
  List<ProcedureParameterMetadata> metadata,
  Map<String, Object?> parameters,
  Set<String> outputParameters,
) {
  final inputs = <String, Object?>{};
  for (final entry in parameters.entries) {
    final name = normalizeParameterName(entry.key);
    if (inputs.containsKey(name)) {
      throw ArgumentError('Duplicate procedure parameter "$name".');
    }
    inputs[name] = entry.value;
  }
  final outputs = outputParameters.map(normalizeParameterName).toSet();
  final known = metadata.map((item) => item.name).toSet();
  for (final name in <String>{...inputs.keys, ...outputs}) {
    if (!known.contains(name)) {
      throw ArgumentError('The procedure has no parameter named "$name".');
    }
  }

  final bindings = <MssqlParameterBinding>[];
  for (final item in metadata) {
    final hasInput = inputs.containsKey(item.name);
    final wantsOutput = outputs.contains(item.name);
    if (!hasInput && !wantsOutput) continue;
    if (item.isReadOnly) {
      throw MssqlException(
        type: MssqlErrorType.unsupportedType,
        message: 'Table-valued parameter "${item.name}" is not supported.',
      );
    }
    if (wantsOutput && !item.isOutput) {
      throw ArgumentError(
        'Procedure parameter "${item.name}" is not declared OUTPUT.',
      );
    }
    final raw = hasInput ? inputs[item.name] : null;
    final value = wantsOutput
        ? coerceMssqlValue(
            raw is MssqlValue ? raw.value : raw,
            type: item.type,
            size: item.size,
            precision: item.precision,
            scale: item.scale,
          )
        : (raw is MssqlValue
              ? raw.validated()
              : coerceMssqlValue(
                  raw,
                  type: item.type,
                  size: item.size,
                  precision: item.precision,
                  scale: item.scale,
                ));
    final direction = wantsOutput
        ? (hasInput
              ? MssqlParameterBindingDirection.inputOutput
              : MssqlParameterBindingDirection.output)
        : MssqlParameterBindingDirection.input;
    bindings.add(
      MssqlParameterBinding.fromValue(item.name, value, direction: direction),
    );
  }
  return bindings;
}
