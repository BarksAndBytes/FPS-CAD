#include "fpcad/Expression.h"

#include <cctype>
#include <cmath>

namespace fpcad {
namespace {

constexpr double kPi = 3.14159265358979323846;

struct Value {
  double v = 0;
  bool hasUnit = false;  // carries a unit (or came from a variable), so it is already SI
};

bool lookupUnit(const std::string& u, double& scale, Quantity& kind) {
  static const std::map<std::string, std::pair<double, Quantity>> table = {
      {"um", {1e-6, Quantity::Length}}, {"mm", {1e-3, Quantity::Length}},
      {"cm", {1e-2, Quantity::Length}}, {"m", {1.0, Quantity::Length}},
      {"km", {1e3, Quantity::Length}},  {"in", {0.0254, Quantity::Length}},
      {"ft", {0.3048, Quantity::Length}}, {"deg", {kPi / 180.0, Quantity::Angle}},
      {"rad", {1.0, Quantity::Angle}},
  };
  auto it = table.find(u);
  if (it == table.end()) return false;
  scale = it->second.first;
  kind = it->second.second;
  return true;
}

class Parser {
public:
  Parser(const std::string& s, const VariableTable& vars, Quantity q, double bare)
      : s_(s), vars_(vars), q_(q), bare_(bare) {}

  double run() {
    Value r = expr();
    skip();
    if (i_ != s_.size()) fail("unexpected '" + std::string(1, s_[i_]) + "'");
    return finish(r).v;
  }

private:
  // A bare number becomes SI using the default unit of the quantity being evaluated.
  Value finish(Value x) const {
    if (x.hasUnit) return x;
    if (q_ == Quantity::Length) return {x.v * bare_, true};
    if (q_ == Quantity::Angle) return {x.v * kPi / 180.0, true};
    return {x.v, true};
  }

  Value expr() {
    Value a = term();
    for (;;) {
      skip();
      if (peek('+') || peek('-')) {
        char op = s_[i_++];
        Value b = term();
        if (a.hasUnit != b.hasUnit) { a = finish(a); b = finish(b); }
        a.v = op == '+' ? a.v + b.v : a.v - b.v;
        a.hasUnit = a.hasUnit || b.hasUnit;
      } else {
        return a;
      }
    }
  }

  Value term() {
    Value a = unary();
    for (;;) {
      skip();
      if (peek('*') || peek('/')) {
        char op = s_[i_++];
        Value b = unary();
        if (op == '/' && b.v == 0) fail("division by zero");
        a.v = op == '*' ? a.v * b.v : a.v / b.v;
        a.hasUnit = a.hasUnit || b.hasUnit;
      } else {
        return a;
      }
    }
  }

  Value unary() {
    skip();
    if (peek('-')) { ++i_; Value v = unary(); v.v = -v.v; return v; }
    if (peek('+')) { ++i_; return unary(); }
    return primary();
  }

  Value primary() {
    skip();
    if (peek('(')) {
      ++i_;
      Value v = expr();
      skip();
      if (!peek(')')) fail("missing ')'");
      ++i_;
      return withUnit(v);
    }
    if (i_ < s_.size() && (std::isdigit(static_cast<unsigned char>(s_[i_])) || s_[i_] == '.')) {
      size_t used = 0;
      double v = std::stod(s_.substr(i_), &used);
      i_ += used;
      return withUnit({v, false});
    }
    if (i_ < s_.size() && (std::isalpha(static_cast<unsigned char>(s_[i_])) || s_[i_] == '_')) {
      std::string name = ident();
      if (name == "pi") return {kPi, false};
      auto it = vars_.find(name);
      if (it == vars_.end()) fail("unknown name '" + name + "'");
      return {it->second, true};
    }
    fail(i_ < s_.size() ? "unexpected '" + std::string(1, s_[i_]) + "'" : "expression ends early");
    return {};
  }

  // Optional unit suffix directly after a number or parenthesis: "12mm", "(a+2) in".
  Value withUnit(Value v) {
    size_t save = i_;
    skip();
    if (i_ < s_.size() && std::isalpha(static_cast<unsigned char>(s_[i_]))) {
      size_t start = i_;
      std::string u = ident();
      double scale;
      Quantity kind;
      if (lookupUnit(u, scale, kind)) {
        if (v.hasUnit) fail("unit '" + u + "' applied twice");
        return {v.v * scale, true};
      }
      (void)start;  // not a unit: leave it for the caller (it will be a syntax error)
    }
    i_ = save;
    return v;
  }

  std::string ident() {
    size_t start = i_;
    while (i_ < s_.size() && (std::isalnum(static_cast<unsigned char>(s_[i_])) || s_[i_] == '_')) ++i_;
    return s_.substr(start, i_ - start);
  }

  void skip() { while (i_ < s_.size() && std::isspace(static_cast<unsigned char>(s_[i_]))) ++i_; }
  bool peek(char c) const { return i_ < s_.size() && s_[i_] == c; }
  [[noreturn]] void fail(const std::string& msg) const {
    throw ExpressionError("\"" + s_ + "\": " + msg);
  }

  const std::string& s_;
  const VariableTable& vars_;
  Quantity q_;
  double bare_;
  size_t i_ = 0;
};

}  // namespace

double unitScale(const std::string& unit) {
  double scale;
  Quantity kind;
  if (!lookupUnit(unit, scale, kind) || kind != Quantity::Length)
    throw ExpressionError("unknown length unit '" + unit + "'");
  return scale;
}

double evaluate(const std::string& expr, const VariableTable& vars, Quantity q, double lengthUnitScale) {
  if (expr.find_first_not_of(" \t") == std::string::npos) throw ExpressionError("empty expression");
  double v = Parser(expr, vars, q, lengthUnitScale).run();
  if (!std::isfinite(v)) throw ExpressionError("\"" + expr + "\": result is not a finite number");
  return v;
}

}  // namespace fpcad
