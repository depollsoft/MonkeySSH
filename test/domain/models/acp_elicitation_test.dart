import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/acp_elicitation.dart';

AcpElicitationRequest _parse(
  Map<String, Object?> params, {
  bool form = true,
  bool url = true,
}) =>
    AcpElicitationRequest.parse(params, formSupported: form, urlSupported: url);

Map<String, Object?> _form(
  Map<String, Object?> properties, {
  List<String> required = const [],
  Map<String, Object?> scope = const {'sessionId': 'session-1'},
}) => {
  ...scope,
  'mode': 'form',
  'message': 'Configure the refactor',
  'requestedSchema': {
    'type': 'object',
    'properties': properties,
    'required': required,
  },
};

Matcher _refused({bool unsupportedMode = false}) => throwsA(
  isA<AcpElicitationRequestException>().having(
    (error) => error.unsupportedMode,
    'unsupportedMode',
    unsupportedMode,
  ),
);

void main() {
  group('AcpElicitationRequest.parse', () {
    test('parses a session-scoped form with every supported field', () {
      final request = _parse(
        _form(
          {
            'name': {
              'type': 'string',
              'title': 'Display name',
              'description': 'Shown to teammates',
              'minLength': 2,
              'maxLength': 20,
              'default': 'Ada',
            },
            'email': {'type': 'string', 'format': 'email'},
            'strategy': {
              'type': 'string',
              'enum': ['conservative', 'balanced'],
              'default': 'balanced',
            },
            'tier': {
              'type': 'string',
              'oneOf': [
                {'const': 'free', 'title': 'Free'},
                {'const': 'pro', 'title': 'Pro'},
              ],
            },
            'retries': {
              'type': 'integer',
              'minimum': 0,
              'maximum': 5,
              'default': 2,
            },
            'ratio': {'type': 'number', 'minimum': 0.5},
            'dryRun': {'type': 'boolean', 'default': true},
            'targets': {
              'type': 'array',
              'items': {
                'type': 'string',
                'enum': ['ios', 'android', 'web'],
              },
              'minItems': 1,
              'maxItems': 2,
              'default': ['ios', 'desktop'],
            },
            'owners': {
              'type': 'array',
              'items': {
                'anyOf': [
                  {'const': 'a', 'title': 'Alice'},
                  {'const': 'b', 'title': 'Bob'},
                ],
              },
            },
          },
          required: ['name', 'strategy', 'unknown'],
          scope: {'sessionId': 'session-1', 'toolCallId': 'call-1'},
        ),
      ) as AcpFormElicitation;

      expect(request.message, 'Configure the refactor');
      expect(request.scope.sessionId, 'session-1');
      expect(request.scope.toolCallId, 'call-1');
      expect(request.scope.isRequestScoped, isFalse);
      final fields = {
        for (final field in request.schema.fields) field.name: field,
      };
      expect(fields.keys, [
        'name',
        'email',
        'strategy',
        'tier',
        'retries',
        'ratio',
        'dryRun',
        'targets',
        'owners',
      ]);
      final name = fields['name']! as AcpStringElicitationField;
      expect(name.label, 'Display name');
      expect(name.isRequired, isTrue);
      expect(name.defaultValue, 'Ada');
      expect(name.inputLimit, 20);
      expect(
        (fields['email']! as AcpStringElicitationField).format,
        AcpElicitationStringFormat.email,
      );
      final strategy = fields['strategy']! as AcpStringElicitationField;
      expect(strategy.options!.map((o) => o.value), [
        'conservative',
        'balanced',
      ]);
      expect(strategy.defaultValue, 'balanced');
      expect(
        (fields['tier']! as AcpStringElicitationField).options!.map(
          (o) => o.title,
        ),
        ['Free', 'Pro'],
      );
      final retries = fields['retries']! as AcpNumberElicitationField;
      expect(retries.integer, isTrue);
      expect(retries.defaultValue, 2);
      expect(
        (fields['dryRun']! as AcpBooleanElicitationField).defaultValue,
        true,
      );
      final targets = fields['targets']! as AcpMultiSelectElicitationField;
      expect(targets.defaultValue, ['ios']);
      expect(targets.minItems, 1);
      expect(
        (fields['owners']! as AcpMultiSelectElicitationField).options.map(
          (o) => o.title,
        ),
        ['Alice', 'Bob'],
      );
      expect(request.canSubmit, isTrue);
    });

    test('parses a request-scoped URL elicitation', () {
      final request = _parse({
        'requestId': 12,
        'mode': 'url',
        'elicitationId': 'github-oauth-001',
        'url': 'https://agent.example.com/connect?id=1',
        'message': 'Authorize repository access.',
      }) as AcpUrlElicitation;
      expect(request.scope.isRequestScoped, isTrue);
      expect(request.scope.requestId, 12);
      expect(request.elicitationId, 'github-oauth-001');
      expect(request.review.host, 'agent.example.com');
      expect(request.review.canOpen, isTrue);
      expect(request.review.needsAcknowledgement, isFalse);
    });

    test('refuses unadvertised and unknown modes as unsupported', () {
      final form = _form({});
      expect(() => _parse(form, form: false), _refused(unsupportedMode: true));
      expect(
        () => _parse({...form, 'mode': 'audio'}),
        _refused(unsupportedMode: true),
      );
      expect(
        () => _parse({
          'sessionId': 's',
          'mode': 'url',
          'elicitationId': 'e',
          'url': 'https://example.com',
          'message': 'm',
        }, url: false),
        _refused(unsupportedMode: true),
      );
    });

    test('refuses structurally invalid requests', () {
      expect(() => _parse({..._form({}), 'mode': null}), _refused());
      expect(() => _parse({..._form({})}..remove('message')), _refused());
      expect(
        () => _parse({..._form({})}..remove('requestedSchema')),
        _refused(),
      );
      expect(() => _parse({..._form({})}..remove('sessionId')), _refused());
      expect(
        () => _parse({
          'sessionId': 's',
          'mode': 'url',
          'url': 'https://example.com',
          'message': 'm',
        }),
        _refused(),
      );
    });

    test('bounds provider-controlled sizes', () {
      expect(
        () => _parse({
          ..._form({}),
          'message': 'x' * (acpElicitationMaxMessageCharacters + 1),
        }),
        _refused(),
      );
      expect(
        () => _parse(
          _form({
            for (var i = 0; i <= acpElicitationMaxProperties; i++)
              'field$i': {'type': 'boolean'},
          }),
        ),
        _refused(),
      );
      expect(
        () => _parse(
          _form({
            'choice': {
              'type': 'string',
              'enum': [
                for (var i = 0; i <= acpElicitationMaxOptions; i++) 'v$i',
              ],
            },
          }),
        ),
        _refused(),
      );
      expect(
        () => _parse(
          _form({
            'x': {
              'type': 'string',
              'pattern': 'a' * (acpElicitationMaxPatternCharacters + 1),
            },
          }),
        ),
        _refused(),
      );
    });

    test('keeps unknown property types as unsupported fields', () {
      final request = _parse(
        _form(
          {
            'optional': {'type': 'object'},
            'files': {
              'type': 'array',
              'items': {'type': 'object'},
            },
          },
          required: ['files'],
        ),
      ) as AcpFormElicitation;
      expect(
        request.schema.fields,
        everyElement(isA<AcpUnsupportedElicitationField>()),
      );
      expect(request.canSubmit, isFalse);
      expect(request.validateContent({}), {
        'files': 'This required field is not supported',
      });
    });

    test('drops invalid defaults instead of refusing the request', () {
      final request = _parse(
        _form({
          'choice': {
            'type': 'string',
            'enum': ['a'],
            'default': 'z',
          },
          'count': {'type': 'integer', 'default': 1.5},
          'flag': {'type': 'boolean', 'default': 'yes'},
          'pattern': {'type': 'string', 'pattern': '('},
        }),
      ) as AcpFormElicitation;
      final fields = request.schema.fields;
      expect((fields[0] as AcpStringElicitationField).defaultValue, isNull);
      expect((fields[1] as AcpNumberElicitationField).defaultValue, isNull);
      expect((fields[2] as AcpBooleanElicitationField).defaultValue, isNull);
      expect((fields[3] as AcpStringElicitationField).pattern, isNull);
    });
  });

  group('field validation', () {
    AcpElicitationField field(
      Map<String, Object?> schema, {
      bool req = false,
    }) => AcpElicitationField.parse('f', schema, isRequired: req);

    test('checks patterns in a worker and abandons runaway ones', () async {
      final form = _parse(
        _form({
          'slug': {'type': 'string', 'pattern': r'^[a-z]+$'},
          'evil': {'type': 'string', 'pattern': r'^(a+)+$'},
        }),
      ) as AcpFormElicitation;
      expect(
        await form.patternMismatches({'slug': 'abc', 'evil': 'aaa'}),
        isEmpty,
      );
      expect(await form.patternMismatches({'slug': 'AB', 'evil': 'aaa'}), {
        'slug',
      });

      // Catastrophic backtracking would run for minutes on the UI isolate.
      final elapsed = Stopwatch()..start();
      final abandoned = await form.patternMismatches({
        'slug': 'AB',
        'evil': '${'a' * 40}!',
      }, budget: const Duration(milliseconds: 200));
      expect(abandoned, isEmpty);
      expect(elapsed.elapsed, lessThan(const Duration(seconds: 5)));
    });

    test('strings honor required, length, pattern, and formats', () {
      final text = field({
        'type': 'string',
        'minLength': 2,
        'maxLength': 4,
        'pattern': r'^[a-z]+$',
      }, req: true);
      expect(text.validate(null), 'Required');
      // An empty answer is present; minLength is what rejects it.
      expect(text.validate(''), 'Use at least 2 characters');
      expect(text.validate('a'), isNotNull);
      expect(text.validate('abcde'), isNotNull);
      // Patterns are checked off the UI isolate at submit, not here.
      expect(text.validate('AB'), isNull);
      expect(text.validate('abc'), isNull);
      // Lengths count code points, not UTF-16 units.
      expect(
        field({'type': 'string', 'maxLength': 2}).validate('😀😀'),
        isNull,
      );

      expect(
        field({'type': 'string', 'format': 'email'}).validate('a@b'),
        isNotNull,
      );
      expect(
        field({'type': 'string', 'format': 'email'}).validate('a@b.dev'),
        isNull,
      );
      expect(
        field({'type': 'string', 'format': 'uri'}).validate('example.com'),
        isNotNull,
      );
      expect(
        field({'type': 'string', 'format': 'uri'}).validate('https://x.dev'),
        isNull,
      );
      expect(
        field({'type': 'string', 'format': 'date'}).validate('2026-02-30'),
        isNotNull,
      );
      expect(
        field({'type': 'string', 'format': 'date'}).validate('2026-02-28'),
        isNull,
      );
      final dateTime = field({'type': 'string', 'format': 'date-time'});
      expect(dateTime.validate('2026-10-01 09:30'), isNotNull);
      expect(dateTime.validate('2026-10-01T09:30:00Z'), isNull);
      expect(dateTime.validate('2026-10-01T09:30:00.5+02:00'), isNull);
      expect(dateTime.validate('2026-10-01T09:30:00-23:59'), isNull);
      expect(dateTime.validate('2026-10-01T09:30:00+99:99'), isNotNull);
      expect(dateTime.validate('2026-10-01T09:30:00+05:60'), isNotNull);
      expect(field({'type': 'string'}).validate(null), isNull);
    });

    test('single choice accepts only offered values', () {
      final choice = field({
        'type': 'string',
        'enum': ['a', 'b'],
      });
      expect(choice.validate('a'), isNull);
      expect(choice.validate('c'), isNotNull);
    });

    test('numbers honor integer-ness and inclusive bounds', () {
      final integer = field({
        'type': 'integer',
        'minimum': 1,
        'maximum': 3,
      }) as AcpNumberElicitationField;
      expect(integer.validate(1), isNull);
      expect(integer.validate(3), isNull);
      expect(integer.validate(0), isNotNull);
      expect(integer.validate(4), isNotNull);
      expect(integer.validate(2.5), isNotNull);
      expect(integer.parse('2'), 2);
      expect(integer.parse('2.0'), isNull);

      // Integer bounds and defaults may be serialized as any number.
      final fractional = field({
        'type': 'integer',
        'minimum': 1.5,
        'maximum': 4.0,
        'default': 2.0,
      }) as AcpNumberElicitationField;
      expect(fractional.minimum, 2);
      expect(fractional.maximum, 4);
      expect(fractional.defaultValue, 2);
      expect(fractional.defaultValue, isA<int>());
      expect(fractional.validate(1), isNotNull);
      expect(fractional.validate(5), isNotNull);
      expect(fractional.validate(4), isNull);

      final number = field({'type': 'number'}) as AcpNumberElicitationField;
      expect(number.parse('2.5'), 2.5);
      expect(number.parse('NaN'), isNull);
      expect(number.parse('Infinity'), isNull);
      expect(number.validate(double.nan), isNotNull);
    });

    test('multi-select honors options, uniqueness, and item bounds', () {
      final multi = field({
        'type': 'array',
        'items': {
          'type': 'string',
          'enum': ['a', 'b', 'c'],
        },
        'minItems': 1,
        'maxItems': 2,
      }, req: true);
      expect(multi.validate(<String>[]), isNotNull);
      expect(multi.validate(['a']), isNull);
      expect(multi.validate(['a', 'b', 'c']), isNotNull);
      expect(multi.validate(['a', 'a']), isNotNull);
      expect(multi.validate(['z']), isNotNull);
    });

    test('required fields accept explicit empty answers the schema allows', () {
      final choice = field({
        'type': 'string',
        'oneOf': [
          {'const': '', 'title': 'None'},
          {'const': 'main', 'title': 'Main'},
        ],
      }, req: true);
      expect(choice.validate(''), isNull);
      expect(choice.validate(null), 'Required');
      expect(choice.validate('other'), isNotNull);
      // `required` only asks for presence: without minLength or a format,
      // an empty string is a valid answer.
      expect(field({'type': 'string'}, req: true).validate(''), isNull);
      expect(field({'type': 'string'}, req: true).validate(null), 'Required');
      expect(
        field({'type': 'string', 'format': 'email'}, req: true).validate(''),
        isNotNull,
      );

      Map<String, Object?> list([Map<String, Object?> extra = const {}]) => {
        'type': 'array',
        'items': {
          'type': 'string',
          'enum': ['a', 'b'],
        },
        ...extra,
      };
      expect(
        field(list({'minItems': 0}), req: true).validate(<String>[]),
        isNull,
      );
      expect(field(list(), req: true).validate(<String>[]), isNull);
      expect(field(list(), req: true).validate(null), 'Required');
      expect(
        field(list({'minItems': 1}), req: true).validate(<String>[]),
        isNotNull,
      );
    });

    test('form content rejects unknown keys and invalid values', () {
      final request = _parse(
        _form(
          {
            'name': {'type': 'string'},
            'count': {'type': 'integer', 'maximum': 2},
          },
          required: ['name'],
        ),
      ) as AcpFormElicitation;
      expect(request.validateContent({'name': 'x'}), isEmpty);
      expect(request.validateContent({'name': 'x', 'count': 3}).keys, [
        'count',
      ]);
      expect(request.validateContent({'name': 'x', 'extra': true}).keys, [
        'extra',
      ]);
      expect(request.validateContent({}).keys, ['name']);
    });
  });

  group('AcpElicitationUrlReview', () {
    test('flags insecure, punycode, and user-info URLs', () {
      final insecure = AcpElicitationUrlReview.of('http://example.com/a');
      expect(insecure.canOpen, isTrue);
      expect(insecure.insecure, isTrue);
      expect(insecure.needsAcknowledgement, isTrue);

      final punycode = AcpElicitationUrlReview.of(
        'https://login.xn--pple-43d.com/',
      );
      expect(punycode.punycode, isTrue);
      expect(punycode.host, 'login.xn--pple-43d.com');

      final userInfo = AcpElicitationUrlReview.of(
        'https://github.com@evil.example/',
      );
      expect(userInfo.hasUserInfo, isTrue);
      expect(userInfo.host, 'evil.example');
    });

    test('never opens non-web or malformed targets', () {
      expect(
        AcpElicitationUrlReview.of('javascript:alert(1)').canOpen,
        isFalse,
      );
      expect(AcpElicitationUrlReview.of('file:///etc/passwd').canOpen, isFalse);
      expect(AcpElicitationUrlReview.of('https://').canOpen, isFalse);
      expect(AcpElicitationUrlReview.of('not a url').canOpen, isFalse);
    });
  });
}
