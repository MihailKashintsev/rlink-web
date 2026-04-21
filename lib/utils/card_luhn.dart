/// Проверка Луна для строки из цифр (без пробелов).
bool passesLuhn(String digitsOnly) {
  if (digitsOnly.length < 13 || digitsOnly.length > 19) return false;
  var sum = 0;
  var alternate = false;
  for (var i = digitsOnly.length - 1; i >= 0; i--) {
    final c = digitsOnly.codeUnitAt(i);
    if (c < 48 || c > 57) return false;
    var d = c - 48;
    if (alternate) {
      d *= 2;
      if (d > 9) d -= 9;
    }
    sum += d;
    alternate = !alternate;
  }
  return sum % 10 == 0;
}
