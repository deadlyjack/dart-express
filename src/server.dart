import 'dart:convert';
import 'dart:io';

class Server with _Router {
  late String host;
  late int port;
  late HttpServer server;

  Server() {
    use(parseBody);
  }

  void listen(String host, int port, Function cb) async {
    try {
      this.host = host;
      this.port = port;
      server = await HttpServer.bind(host, port);
      _init(server);
      cb();
    } catch (error) {
      print(error);
    }
  }

  void _init(HttpServer server) {
    server.listen((req) {
      final localCopyOfMiddleWares = [...middlewares];
      final serverReq = ServerRequest(req);
      final serverRes = ServerResponse(req.response);
      _serverHandler(serverReq, serverRes, localCopyOfMiddleWares);
    });
  }

  void _serverHandler(ServerRequest req, ServerResponse res, List<Middleware> middlewares) async {
    if (middlewares.isNotEmpty) {
      final middleware = middlewares.removeAt(0);
      middleware(req, res, () => _serverHandler(req, res, middlewares));
      return;
    }

    final handlers = getHanderls(req.method);

    List<Function> cbs = [];
    for (final handler in handlers) {
      final result = _testPath(handler.path, req.path);

      if (result == null) {
        continue;
      }

      req.params = result.params;
      req.queries = result.queries;
      cbs.add((Function next) {
        final cb = handler.cb;
        if (cb is Middleware) {
          cb(req, res, next);
        } else {
          cb(req, res);
        }
      });
    }

    if (cbs.isEmpty) {
      res.code(404).send('Not Found');
      return;
    }

    _execute(cbs);
  }

  void _execute(List<Function> cbs) {
    if (cbs.isNotEmpty) {
      final cb = cbs.removeAt(0);
      cb(() => _execute(cbs));
    }
  }

  _TestResult? _testPath(String path, String reqPath) {
    if (path == reqPath) {
      return _TestResult();
    }

    String query = '';

    if (reqPath.contains('?')) {
      final parts = reqPath.split('?');
      reqPath = parts[0];
      query = parts[1];
    }

    final pathParts = path.split('/');
    final reqPathParts = reqPath.split('/');
    final params = <String, String>{};
    bool match = false;

    for (var i = 0; i < pathParts.length; i++) {
      // do not lowercase because of params
      String pathPart = pathParts[i];
      String reqPathPart = reqPathParts[i];

      if (pathPart.startsWith(':')) {
        final key = pathPart.substring(1);
        params[key] = reqPathPart;
        match = true;
        continue;
      }

      if (pathPart.startsWith('(')) {
        // test regex
        final regex = RegExp(pathPart);
        if (regex.hasMatch(reqPathPart)) {
          match = true;
          continue;
        }
      }

      pathPart = pathPart.toLowerCase();
      reqPathPart = reqPathPart.toLowerCase();

      if (pathPart == '*') {
        match = true;
        break;
      }

      if (pathPart != reqPathPart) {
        match = false;
        break;
      }
    }

    if (match) {
      if (query.isNotEmpty) {
        return _TestResult(params, _parseQuery(query));
      }
      return _TestResult(params);
    }

    return null;
  }

  Map<String, dynamic> _parseQuery(String query) {
    final result = <String, dynamic>{};
    final queryParts = query.split('&');

    for (final queryPart in queryParts) {
      final queryPartParts = queryPart.split('=');
      final key = queryPartParts[0];
      final value = queryPartParts[1];
      final prevValue = result[key];

      if (prevValue != null) {
        if (prevValue is List) {
          prevValue.add(value);
        } else {
          result[key] = [prevValue, value];
        }

        continue;
      }

      result[key] = value;
    }

    return result;
  }

  void parseBody(ServerRequest req, ServerResponse res, Function next) async {
    final contentType = req.httpRequest.headers.contentType;

    switch (contentType?.mimeType) {
      case 'application/json':
        req.body = jsonDecode(await req.body);
        break;

      case 'multipart/form-data':
        req.body = await _parseFormData(req);
        break;

      default:
        break;
    }
    next();
  }

  Future<Map<String, String>> _parseFormData(ServerRequest req) async {
    final boundary = req.httpRequest.headers.contentType?.parameters['boundary'];
    final body = await req.body;
    final result = <String, String>{};

    if (boundary == null) {
      return result;
    }

    final parts = body.split(boundary);

    for (final part in parts) {
      if (part.isEmpty || part.startsWith('--')) {
        continue;
      }

      print('***************$part********************');
      // result[name] = value;
    }

    return result;
  }
}

class Router with _Router {
  final String path;

  Router(this.path);
}

class ServerRequest {
  dynamic _body;
  final HttpRequest httpRequest;

  Map<String, String> params = {};
  Map<String, dynamic> queries = {};

  ServerRequest(this.httpRequest);

  String get method => httpRequest.method;
  String get path => httpRequest.uri.path;
  String get query => httpRequest.uri.query;

  Future<String> get body {
    if (_body != null) {
      return _body;
    }

    _body = utf8.decodeStream(httpRequest);
    return _body;
  }

  set body(dynamic body) {
    _body = body;
  }
}

class ServerResponse {
  final HttpResponse httpResponse;

  ServerResponse(this.httpResponse);

  ServerResponse code(int code) {
    httpResponse.statusCode = code;
    return this;
  }

  void send(dynamic data) {
    httpResponse.write(data);
    httpResponse.close();
  }

  void json(dynamic data) {
    httpResponse.headers.contentType = ContentType.json;
    httpResponse.write(jsonEncode(data));
    httpResponse.close();
  }
}

class _TestResult {
  Map<String, String> params = {};
  Map<String, dynamic> queries = {};

  _TestResult([Map<String, String>? params, Map<String, dynamic>? queries]) {
    if (params != null) {
      this.params = params;
    }
    if (queries != null) {
      this.queries = queries;
    }
  }
}

mixin _Router {
  static const GET = 'GET';
  static const POST = 'POST';
  static const PUT = 'PUT';
  static const DELETE = 'DELETE';
  static const PATCH = 'PATCH';
  static const USE = 'USE';

  final String path = '';
  final List<_Listener> _listeners = [];
  final List<Middleware> _middlewares = [];

  void _addListener(String method, String path, Function cb) {
    if (this.path.isNotEmpty) {
      path = _join([this.path, path]);
    }

    _listeners.add(_Listener(method, path, cb));
  }

  void get(String path, Function cb) {
    _addListener(GET, path, cb);
  }

  void post(String path, Function cb) {
    _addListener(POST, path, cb);
  }

  void put(String path, Function cb) {
    _addListener(PUT, path, cb);
  }

  void delete(String path, Function cb) {
    _addListener(DELETE, path, cb);
  }

  void patch(String path, Function cb) {
    _addListener(PATCH, path, cb);
  }

  void use(dynamic route, [Function? cb]) {
    if (route is Router) {
      _listeners.addAll(route._listeners);
      _middlewares.addAll(route._middlewares);
      return;
    } else if (route is Middleware) {
      _middlewares.add(route);
      return;
    } else if (route is String && cb is Function) {
      _addListener(USE, route, cb);
      return;
    }
  }

  List<_Listener> getHanderls(String method) {
    return _listeners.where((listener) => [USE, method].contains(listener.method)).toList();
  }

  List<Middleware> get middlewares => _middlewares;
}

class _Listener {
  final String method;
  final String path;
  final Function cb;

  _Listener(this.method, this.path, this.cb);
}

String _join(List<String> paths) {
  List<String> res = [];

  for (var path in paths) {
    final pathSegs = path.split('/');

    for (var pathSeg in pathSegs) {
      if (pathSeg == '..') {
        res.removeLast();
        continue;
      }

      res.add(pathSeg);
    }
  }

  return res.where((pathSeg) => pathSeg.isNotEmpty).join('/');
}

typedef Handler = void Function(ServerRequest, ServerResponse);
typedef Middleware = void Function(ServerRequest, ServerResponse, Function);
typedef HandlerWithNext = void Function(ServerRequest, ServerResponse, Function);
