import 'package:flutter/material.dart';

/// App-wide [ScaffoldMessengerState] key, set on [MaterialApp.router] in
/// app.dart. Lets background work outside any screen's [BuildContext] (e.g.
/// [AuthNotifier]'s auto clock-in/out) surface a SnackBar that survives the
/// login ⇄ dashboard navigation happening around it.
final scaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();

void showAppSnackBar(String message) {
  scaffoldMessengerKey.currentState
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}
