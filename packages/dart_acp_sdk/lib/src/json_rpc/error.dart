/// A JSON-RPC error object.
final class JsonRpcErrorObject {
  /// Creates an error object.
  factory JsonRpcErrorObject({
    required int code,
    required String message,
    Object? data,
    bool hasData = false,
  }) {
    if (code < minimumCode || code > maximumCode) {
      throw RangeError.range(
        code,
        minimumCode,
        maximumCode,
        'code',
        'must fit a signed 32-bit integer',
      );
    }
    return JsonRpcErrorObject._(
      code: code,
      message: message,
      data: data,
      hasData: hasData,
    );
  }

  const JsonRpcErrorObject._({
    required this.code,
    required this.message,
    required this.data,
    required this.hasData,
  });

  /// The smallest error code representable by the ACP schema.
  static const int minimumCode = -0x80000000;

  /// The largest error code representable by the ACP schema.
  static const int maximumCode = 0x7fffffff;

  /// The numeric JSON-RPC error code.
  final int code;

  /// The human-readable error message.
  final String message;

  /// Optional structured error data.
  final Object? data;

  /// Whether `data` was explicitly present, including as JSON `null`.
  final bool hasData;

  /// Encodes this object for JSON.
  Map<String, Object?> toJson() => <String, Object?>{
    'code': code,
    'message': message,
    if (hasData) 'data': data,
  };

  @override
  bool operator ==(Object other) =>
      other is JsonRpcErrorObject &&
      other.code == code &&
      other.message == message &&
      other.data == data &&
      other.hasData == hasData;

  @override
  int get hashCode => Object.hash(code, message, data, hasData);
}

/// An error returned by a JSON-RPC peer or request handler.
final class JsonRpcRequestException implements Exception {
  /// Creates a request exception from an error object.
  const JsonRpcRequestException(this.error);

  /// Creates the standard parse error.
  factory JsonRpcRequestException.parseError({Object? data}) =>
      JsonRpcRequestException(
        JsonRpcErrorObject(
          code: -32700,
          message: 'Parse error',
          data: data,
          hasData: data != null,
        ),
      );

  /// Creates the standard invalid-request error.
  factory JsonRpcRequestException.invalidRequest({Object? data}) =>
      JsonRpcRequestException(
        JsonRpcErrorObject(
          code: -32600,
          message: 'Invalid request',
          data: data,
          hasData: data != null,
        ),
      );

  /// Creates the standard method-not-found error.
  factory JsonRpcRequestException.methodNotFound(String method) =>
      JsonRpcRequestException(
        JsonRpcErrorObject(
          code: -32601,
          message: '"Method not found": $method',
          data: <String, Object?>{'method': method},
          hasData: true,
        ),
      );

  /// Creates the standard invalid-params error.
  factory JsonRpcRequestException.invalidParams({Object? data}) =>
      JsonRpcRequestException(
        JsonRpcErrorObject(
          code: -32602,
          message: 'Invalid params',
          data: data,
          hasData: data != null,
        ),
      );

  /// Creates the standard internal error.
  factory JsonRpcRequestException.internalError({Object? data}) =>
      JsonRpcRequestException(
        JsonRpcErrorObject(
          code: -32603,
          message: 'Internal error',
          data: data,
          hasData: data != null,
        ),
      );

  /// Creates the request-cancelled error.
  factory JsonRpcRequestException.requestCancelled({Object? data}) =>
      JsonRpcRequestException(
        JsonRpcErrorObject(
          code: -32800,
          message: 'Request cancelled',
          data: data,
          hasData: data != null,
        ),
      );

  /// Creates the authentication-required error.
  factory JsonRpcRequestException.authenticationRequired({Object? data}) =>
      JsonRpcRequestException(
        JsonRpcErrorObject(
          code: -32000,
          message: 'Authentication required',
          data: data,
          hasData: data != null,
        ),
      );

  /// Creates the resource-not-found error.
  factory JsonRpcRequestException.resourceNotFound({String? uri}) =>
      JsonRpcRequestException(
        JsonRpcErrorObject(
          code: -32002,
          message: uri == null
              ? 'Resource not found'
              : 'Resource not found: $uri',
          data: uri == null ? null : <String, Object?>{'uri': uri},
          hasData: uri != null,
        ),
      );

  /// The JSON-RPC error.
  final JsonRpcErrorObject error;

  /// The numeric error code.
  int get code => error.code;

  /// The human-readable message.
  String get message => error.message;

  /// Optional structured error data.
  Object? get data => error.data;

  @override
  String toString() => error.hasData && data != null
      ? 'JsonRpcRequestException($code, $message, $data)'
      : 'JsonRpcRequestException($code, $message)';
}

/// A malformed JSON-RPC wire value.
final class JsonRpcFormatException extends FormatException {
  /// Creates a format exception.
  JsonRpcFormatException(super.message, [super.source]);
}
