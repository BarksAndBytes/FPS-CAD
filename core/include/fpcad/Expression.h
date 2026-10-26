#pragma once
// Parameter expressions: "12", "12 mm", "width / 2 + 3 mm", "2 * (a + b)", "30 deg".
//
// All results are in SI units (metres, radians). A number written without a unit takes the
// document's default unit for lengths, so "12" in a millimetre document means 0.012 m.

#include <map>
#include <stdexcept>
#include <string>

namespace fpcad {

class ExpressionError : public std::runtime_error {
public:
  using std::runtime_error::runtime_error;
};

enum class Quantity { Length, Angle, Count };

// Variables are stored already evaluated, in SI units.
using VariableTable = std::map<std::string, double>;

// Metres per one document unit ("mm" -> 0.001). Throws ExpressionError for unknown units.
double unitScale(const std::string& unit);

// Evaluates an expression. lengthUnitScale is metres per bare number for length quantities.
double evaluate(const std::string& expr, const VariableTable& vars, Quantity q, double lengthUnitScale);

}  // namespace fpcad
