/// Грубая эвристика языка по содержимому фрагмента кода (для подписи в UI).
String guessProgrammingLanguage(String code) {
  final s = code.trim();
  if (s.isEmpty) return 'Код';

  final lower = s.toLowerCase();
  if (lower.contains('select ') && lower.contains(' from ')) return 'SQL';
  if (lower.startsWith('<?php') || lower.contains('<?=')) return 'PHP';
  if (RegExp(r'\bfun\b').hasMatch(s) && RegExp(r'\bval\b|\bvar\b').hasMatch(s)) {
    return 'Kotlin';
  }
  if (RegExp(r'\bfunc\s+\w+\s*\(').hasMatch(s) && s.contains('package ')) {
    return 'Go';
  }
  if (RegExp(r'\b(def|import|from)\b').hasMatch(lower) && lower.contains(':')) {
    return 'Python';
  }
  if (RegExp(r'\b(let|const)\s+\w+').hasMatch(s) && s.contains('=>')) {
    return 'JavaScript';
  }
  if (lower.contains('#include') && lower.contains('int main')) return 'C/C++';
  if (RegExp(r'\bpublic\s+static\s+void\s+main\b').hasMatch(lower)) return 'Java';
  if (RegExp(r'\bfn\s+\w+').hasMatch(s) && lower.contains('let mut')) return 'Rust';
  if (RegExp(r'\bconsole\.(log|error)\b').hasMatch(lower)) return 'JavaScript';
  if (RegExp(r'<\/?[a-z]+[^>]*>', caseSensitive: false).hasMatch(s) &&
      lower.contains('<div')) {
    return 'HTML';
  }
  if (lower.contains('@media') || lower.contains('{') && lower.contains('px;')) {
    return 'CSS';
  }
  if (lower.contains('type ') && lower.contains('interface ') && lower.contains(':')) {
    return 'TypeScript';
  }
  if (lower.contains('dart:') || lower.contains('void main()')) return 'Dart';
  if (lower.contains('package:flutter')) return 'Dart/Flutter';

  return 'Код';
}
