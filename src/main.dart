import 'server.dart';

void main(final List<String> args) async {
  final app = Server();
  String msg = 'Dart';

  app.use('/', (ServerRequest req, ServerResponse res, Function next) {
    msg = "Middleware added";
    next();
  });

  app.post('/user', (ServerRequest req, ServerResponse res) {
    print('body ${req.body}');
    res.send('OK');
  });

  app.get('/', (ServerRequest req, ServerResponse res) {
    res.send(msg);
  });

  app.get('/hello/:name', (req, res) {
    String name = req.params['name'];
    res.send('Hello $name');
  });

  app.listen('localhost', 3001, () {
    print('Server listening on port ${app.port}');
  });
}
