class Report {
  Report(this.lines);

  final List<String> lines;

  void dump() {
    for (final line in lines) {
      print(line);
    }
    print('total: ${lines.length}');
  }

  static void banner() => print('== report ==');
}

class Printer {
  // A user-defined print: calls to it must stay.
  void print(String s) => _buffer.write(s);
  final _buffer = StringBuffer();

  void greet() => print('hello');
}

void printAll(List<Object> items) {
  items.forEach(print);
  print('printed ${items.length} items');
}
