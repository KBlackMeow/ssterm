# Ollama tool contract check

The local mock implements the tool-call round trip documented at
https://docs.ollama.com/capabilities/tool-calling and https://docs.ollama.com/api/chat.
It validates the native request shape and returns fixture calls; it does not run a model.
It was built from public documentation, without a published owner mock search.

Start the simulation (Postman CLI 1.70+):

```sh
postman simulation run postman/simulations/ollama-tools.sim.yaml --port 4962 --output ndjson
```

In another terminal, run the actual Dart client against it:

```sh
flutter test --dart-define=OLLAMA_TEST_BASE_URL=http://127.0.0.1:4962/ollama test/services/agent_ollama_tools_test.dart
```

Without the define, the tests use a local HTTP fixture and skip only the Postman check.
Real model tool-calling quality still needs verification against a tool-capable Ollama model.
