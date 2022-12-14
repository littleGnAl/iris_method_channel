import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:isolate';
import 'dart:typed_data';
import 'package:async/async.dart';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart' show SynchronousFuture, debugPrint;
import 'package:iris_method_channel/iris_method_channel.dart';
import 'package:iris_method_channel/src/native_bindings_delegate.dart';
import 'package:iris_method_channel/src/native_iris_api_rtm_bindings_delegate.dart';

import 'bindings/native_iris_api_rtm_engine_bindings.dart';

// ignore_for_file: public_member_api_docs

class IrisMethodCall {
  const IrisMethodCall(this.funcName, this.params,
      {this.buffers, this.rawBufferParams});
  final String funcName;
  final String params;
  final List<Uint8List>? buffers;
  final List<BufferParam>? rawBufferParams;
}

const int kBasicResultLength = 64 * 1024;

class CallApiResult {
  CallApiResult({required this.irisReturnCode, required this.data});

  final int irisReturnCode;

  final Map<String, dynamic> data;
}

class _EventHandlerHolderKey {
  const _EventHandlerHolderKey({
    required this.registerName,
    required this.unregisterName,
  });
  final String registerName;
  final String unregisterName;

  @override
  bool operator ==(Object other) {
    if (other.runtimeType != runtimeType) {
      return false;
    }
    return other is _EventHandlerHolderKey &&
        other.registerName == registerName &&
        other.unregisterName == unregisterName;
  }

  @override
  int get hashCode => Object.hash(registerName, unregisterName);
}

class _EventHandlerHolder
    with ScopedDisposableObjectMixin
    implements DisposableObject {
  _EventHandlerHolder({required this.key});
  final _EventHandlerHolderKey key;
  final Set<EventLoopEventHandler> _eventHandlers = {};

  int nativeEventHandlerIntPtr = 0;

  void addEventHandler(EventLoopEventHandler eventHandler) {
    _eventHandlers.add(eventHandler);
  }

  Future<void> removeEventHandler(EventLoopEventHandler eventHandler) async {
    _eventHandlers.remove(eventHandler);
    if (_eventHandlers.isEmpty) {}
  }

  Set<EventLoopEventHandler> getEventHandlers() => _eventHandlers;

  @override
  Future<void> dispose() {
    _eventHandlers.clear();
    return SynchronousFuture(null);
  }
}

Uint8List uint8ListFromPtr(int intPtr, int length) {
  final ptr = ffi.Pointer<ffi.Uint8>.fromAddress(intPtr);
  final memoryList = ptr.asTypedList(length);
  return Uint8List.fromList(memoryList);
}

ffi.Pointer<ffi.Void> uint8ListToPtr(Uint8List buffer) {
  ffi.Pointer<ffi.Void> bufferPointer;

  final ffi.Pointer<ffi.Uint8> bufferData =
      calloc.allocate<ffi.Uint8>(buffer.length);

  final pointerList = bufferData.asTypedList(buffer.length);
  pointerList.setAll(0, buffer);

  bufferPointer = bufferData.cast<ffi.Void>();
  return bufferPointer;
}

void freePointer(ffi.Pointer<ffi.Void> ptr) {
  calloc.free(ptr);
}

class _Messenger implements DisposableObject {
  const _Messenger(this.requestPort, this.responseQueue);
  final SendPort requestPort;
  final StreamQueue<dynamic> responseQueue;

  Future<CallApiResult> send(_Request request) async {
    requestPort.send(request);
    return await responseQueue.next;
  }

  Future<List<CallApiResult>> listSend(_Request request) async {
    requestPort.send(request);
    return await responseQueue.next;
  }

  @override
  Future<void> dispose() async {
    requestPort.send(null);
    await responseQueue.cancel();
  }
}

class IrisMethodChannel {
  IrisMethodChannel();

  bool _initilized = false;
  late final _Messenger messenger;
  late final StreamSubscription evntSubscription;
  final ScopedObjects scopedEventHandlers = ScopedObjects();

  static Future<void> _execute(List<Object?> args) async {
    SendPort mainApiCallSendPort = args[0] as SendPort;
    SendPort mainEventSendPort = args[1] as SendPort;
    ffi.Pointer<ffi.Void>? irisApiEnginePtr;
    List<ffi.Pointer<ffi.Void>> argsInner = [];
    // We only aim to pass the irisApiEngine to the executor in the integration test (debug mode)
    assert(() {
      if (args.length > 2) {
        final intptr = args[2] as int?;
        if (intptr != null) {
          irisApiEnginePtr = ffi.Pointer.fromAddress(intptr);
          argsInner = [irisApiEnginePtr!];
        }
      }

      return true;
    }());

    // Send a SendPort to the main isolate so that it can send JSON strings to
    // this isolate.
    // final apiCallPort = ReceivePort('IrisApiEngine_ApiCallPort');
    final apiCallPort = ReceivePort();
    // final eventPort = ReceivePort('IrisApiEngine_EventPort');

    final nativeBindingDelegate = NativeIrisApiRtmBindingsDelegate();

    _IrisMethodChannelNative executor =
        _IrisMethodChannelNative(nativeBindingDelegate);
    executor.initilize(mainEventSendPort, argsInner);
    mainApiCallSendPort.send([
      apiCallPort.sendPort,
    ]);

    // Wait for messages from the main isolate.
    await for (final request in apiCallPort) {
      if (request == null) {
        // Exit if the main isolate sends a null message, indicating there are no
        // more files to read and parse.
        break;
      }

      assert(request is _Request);

      if (request is _ApiCallRequest) {
        final result = executor.invokeMethod(request.methodCall);

        mainApiCallSendPort.send(result);
      } else if (request is _ApiCallListRequest) {
        final results = <CallApiResult>[];
        for (final methodCall in request.methodCalls) {
          final result = executor.invokeMethod(methodCall);
          results.add(result);
        }

        mainApiCallSendPort.send(results);
      } else if (request is _CreateNativeEventHandlerRequest) {
        final result = executor.createNativeEventHandler(request.methodCall);
        mainApiCallSendPort.send(result);
      } else if (request is _CreateNativeEventHandlerListRequest) {
        final results = <CallApiResult>[];
        for (final methodCall in request.methodCalls) {
          final result = executor.createNativeEventHandler(methodCall);
          results.add(result);
        }

        mainApiCallSendPort.send(results);
      } else if (request is _DestroyNativeEventHandlerRequest) {
        final result = executor.destroyNativeEventHandler(request.methodCall);
        mainApiCallSendPort.send(result);
      } else if (request is _DestroyNativeEventHandlerListRequest) {
        final results = <CallApiResult>[];
        for (final methodCall in request.methodCalls) {
          final result = executor.destroyNativeEventHandler(methodCall);
          results.add(result);
        }

        mainApiCallSendPort.send(results);
      }
    }

    executor.dispose();
    Isolate.exit();
  }

  Future<void> initilize() async {
    if (_initilized) return;

    final apiCallPort = ReceivePort();
    final eventPort = ReceivePort();
    await Isolate.spawn(_execute, [
      apiCallPort.sendPort,
      eventPort.sendPort,
    ]);

    // Convert the ReceivePort into a StreamQueue to receive messages from the
    // spawned isolate using a pull-based interface. Events are stored in this
    // queue until they are accessed by `events.next`.
    // final events = StreamQueue<dynamic>(p);
    final responseQueue = StreamQueue<dynamic>(apiCallPort);

    // The first message from the spawned isolate is a SendPort. This port is
    // used to communicate with the spawned isolate.
    // SendPort sendPort = await events.next;
    final msg = await responseQueue.next;
    final requestPort = msg[0];

    messenger = _Messenger(requestPort, responseQueue);

    evntSubscription = eventPort.listen((message) {
      final eventMessage = IrisEvent.parseMessage(message);

      bool handled = false;
      for (final es in scopedEventHandlers.values) {
        final _EventHandlerHolder eh = es as _EventHandlerHolder;
        for (final e in eh.getEventHandlers()) {
          if (e.handleEvent(
              eventMessage.event, eventMessage.data, eventMessage.buffers)) {
            handled = true;
          }
        }

        if (handled) {
          break;
        }
      }
    });

    _initilized = true;
  }

  Future<CallApiResult> invokeMethod(IrisMethodCall methodCall) async {
    final CallApiResult result =
        await messenger.send(_ApiCallRequest(methodCall));

    return result;
  }

  Future<void> dispose() async {
    if (!_initilized) return;
    await scopedEventHandlers.clear();
    await evntSubscription.cancel();

    await messenger.dispose();
  }

  Future<CallApiResult> registerEventHandler(
      ScopedEvent scopedEvent, String params) async {
    final _EventHandlerHolder holder = scopedEventHandlers.putIfAbsent(
        scopedEvent.scopedKey,
        () => _EventHandlerHolder(
              key: _EventHandlerHolderKey(
                registerName: scopedEvent.registerName,
                unregisterName: scopedEvent.unregisterName,
              ),
            ));

    late CallApiResult result;
    if (holder.getEventHandlers().isEmpty) {
      result = await messenger.send(_CreateNativeEventHandlerRequest(
          IrisMethodCall(scopedEvent.registerName, params)));

      final nativeEventHandlerIntPtr = result.data['observerIntPtr']!;
      holder.nativeEventHandlerIntPtr = nativeEventHandlerIntPtr;
    } else {
      result = CallApiResult(irisReturnCode: 0, data: {'result': 0});
    }

    holder.addEventHandler(scopedEvent.handler);

    return result;
  }

  Future<CallApiResult> unregisterEventHandler(
      ScopedEvent scopedEvent, String params) async {
    final _EventHandlerHolder? holder =
        scopedEventHandlers.get(scopedEvent.scopedKey);
    late CallApiResult result;
    if (holder != null) {
      holder.removeEventHandler(scopedEvent.handler);
      if (holder.getEventHandlers().isEmpty) {
        result = await messenger.send(_DestroyNativeEventHandlerRequest(
          IrisMethodCall(
            scopedEvent.unregisterName,
            params,
            rawBufferParams: [BufferParam(holder.nativeEventHandlerIntPtr, 1)],
          ),
        ));
        return result;
      }
    }

    result = CallApiResult(irisReturnCode: 0, data: {'result': 0});
    return result;
  }

  Future<void> unregisterEventHandlers(TypedScopedKey scopedKey) async {
    final _EventHandlerHolder? holder = scopedEventHandlers.get(scopedKey);
    if (holder != null) {
      await holder.dispose();

      final methodCalls = holder
          .getEventHandlers()
          .map((e) => IrisMethodCall(
                holder.key.unregisterName,
                '',
                rawBufferParams: [
                  BufferParam(holder.nativeEventHandlerIntPtr, 1)
                ],
              ))
          .toList();

      await messenger
          .listSend(_DestroyNativeEventHandlerListRequest(methodCalls));
    }
  }
}

abstract class _Request {}

abstract class _IrisMethodCallRequest implements _Request {
  const _IrisMethodCallRequest(this.methodCall);

  final IrisMethodCall methodCall;
}

abstract class _IrisMethodCallListRequest implements _Request {
  const _IrisMethodCallListRequest(this.methodCalls);

  final List<IrisMethodCall> methodCalls;
}

class _ApiCallRequest extends _IrisMethodCallRequest {
  const _ApiCallRequest(IrisMethodCall methodCall) : super(methodCall);
}

// ignore: unused_element
class _ApiCallListRequest extends _IrisMethodCallListRequest {
  const _ApiCallListRequest(List<IrisMethodCall> methodCalls)
      : super(methodCalls);
}

class _CreateNativeEventHandlerRequest extends _IrisMethodCallRequest {
  const _CreateNativeEventHandlerRequest(IrisMethodCall methodCall)
      : super(methodCall);
}

// ignore: unused_element
class _CreateNativeEventHandlerListRequest extends _IrisMethodCallListRequest {
  const _CreateNativeEventHandlerListRequest(List<IrisMethodCall> methodCalls)
      : super(methodCalls);
}

class _DestroyNativeEventHandlerRequest extends _IrisMethodCallRequest {
  const _DestroyNativeEventHandlerRequest(IrisMethodCall methodCall)
      : super(methodCall);
}

class _DestroyNativeEventHandlerListRequest extends _IrisMethodCallListRequest {
  const _DestroyNativeEventHandlerListRequest(List<IrisMethodCall> methodCalls)
      : super(methodCalls);
}

class _IrisMethodChannelNative {
  _IrisMethodChannelNative(this._nativeIrisApiEngineBinding);
  final NativeBindingDelegate _nativeIrisApiEngineBinding;
  ffi.Pointer<ffi.Void>? _irisApiEnginePtr;

  late final IrisEvent _irisEvent;
  ffi.Pointer<IrisCEventHandler>? _irisCEventHandler;
  ffi.Pointer<ffi.Void>? _irisEventHandler;

  void initilize(SendPort sendPort, List<ffi.Pointer<ffi.Void>> args) {
    _nativeIrisApiEngineBinding.initialize();

    _irisApiEnginePtr = _nativeIrisApiEngineBinding.createNativeApiEngine(args);

    _irisEvent = IrisEvent();
    // _irisEvent.setEventHandler(_SendableIrisEventHandler(sendPort));

    _irisEvent.registerEventHandler(sendPort);

    _irisCEventHandler = calloc<IrisCEventHandler>()
          ..ref.OnEvent = _irisEvent.onEventPtr.cast()
        // ..ref.OnEventEx = _irisEvent.onEventExPtr
        ;

    _irisEventHandler =
        _nativeIrisApiEngineBinding.createIrisEventHandler(_irisCEventHandler!);
  }

  CallApiResult _invokeMethod(
    String funcName,
    String params, {
    List<BufferParam>? bufferList,
  }) {
    assert(_irisApiEnginePtr != null, 'Make sure initilize() has been called.');

    return using<CallApiResult>((Arena arena) {
      final ffi.Pointer<ffi.Int8> resultPointer =
          arena.allocate<ffi.Int8>(kBasicResultLength);

      final ffi.Pointer<ffi.Int8> funcNamePointer =
          funcName.toNativeUtf8(allocator: arena).cast();

      final ffi.Pointer<Utf8> paramsPointerUtf8 =
          params.toNativeUtf8(allocator: arena);
      final paramsPointerUtf8Length = paramsPointerUtf8.length;
      final ffi.Pointer<ffi.Int8> paramsPointer = paramsPointerUtf8.cast();

      // ffi.Pointer<ffi.Void> bufferPointer;
      ffi.Pointer<ffi.Pointer<ffi.Void>> bufferListPtr;
      ffi.Pointer<ffi.Uint32> bufferListLengthPtr = ffi.nullptr;
      int bufferLength = bufferList?.length ?? 0;

      if (bufferList != null) {
        bufferListPtr =
            arena.allocate(bufferList.length * ffi.sizeOf<ffi.Uint64>());

        // bufferListLengthPtr = arena.allocate<ffi.Uint32>(bufferList.length);

        for (int i = 0; i < bufferList.length; i++) {
          final bufferParam = bufferList[i];
          bufferListPtr[i] = ffi.Pointer.fromAddress(bufferParam.intPtr);
          // ffi.Pointer<ffi.Uint64>.fromAddress(bufferParam.intPtr).cast();
          // bufferListLengthPtr[i] = bufferParam.length;
        }
      } else {
        bufferListPtr = ffi.nullptr;
        bufferListLengthPtr = ffi.nullptr;
      }

      try {
        final apiParam = arena<ApiParam>()
          ..ref.event = funcNamePointer
          ..ref.data = paramsPointer
          ..ref.data_size = paramsPointerUtf8Length
          ..ref.result = resultPointer
          ..ref.buffer = bufferListPtr
          ..ref.length = bufferListLengthPtr
          ..ref.buffer_count = bufferLength;

        final irisReturnCode =
            _nativeIrisApiEngineBinding.callApi(_irisApiEnginePtr!, apiParam);

        if (irisReturnCode != 0) {
          return CallApiResult(irisReturnCode: irisReturnCode, data: const {});
        }

        final result = resultPointer.cast<Utf8>().toDartString();

        final resultMap = Map<String, dynamic>.from(jsonDecode(result));

        return CallApiResult(irisReturnCode: irisReturnCode, data: resultMap);
      } catch (e) {
        debugPrint(
            '[_ApiCallExecutor] $funcName, params: $params\nerror: ${e.toString()}');
        return CallApiResult(irisReturnCode: -1, data: const {});
      }
    });
  }

  CallApiResult invokeMethod(IrisMethodCall methodCall) {
    return using<CallApiResult>((Arena arena) {
      final funcName = methodCall.funcName;
      final params = methodCall.params;
      final buffers = methodCall.buffers;
      final rawBufferParams = methodCall.rawBufferParams;
      assert(!(buffers != null && rawBufferParams != null));

      int bufferLength = buffers?.length ?? 0;

      List<BufferParam>? buffersPtrList = [];

      if (buffers != null) {
        for (int i = 0; i < bufferLength; i++) {
          final buffer = buffers[i];
          if (buffer.isEmpty) {
            buffersPtrList.add(const BufferParam(0, 0));
            continue;
          }
          final ffi.Pointer<ffi.Uint8> bufferData =
              arena.allocate<ffi.Uint8>(buffer.length);

          final pointerList = bufferData.asTypedList(buffer.length);
          pointerList.setAll(0, buffer);

          buffersPtrList.add(BufferParam(bufferData.address, buffer.length));
        }

        return _invokeMethod(funcName, params, bufferList: buffersPtrList);
      }

      return _invokeMethod(funcName, params, bufferList: rawBufferParams);
    });
  }

  void dispose() {
    assert(_irisApiEnginePtr != null);

    // _destroyObservers();

    _irisEvent.dispose();

    _nativeIrisApiEngineBinding.destroyIrisEventHandler(_irisEventHandler!);
    _irisEventHandler = null;

    calloc.free(_irisCEventHandler!);
    _irisCEventHandler = null;

    _nativeIrisApiEngineBinding.destroyNativeApiEngine(_irisApiEnginePtr!);
    _irisApiEnginePtr = null;
  }

  CallApiResult createNativeEventHandler(IrisMethodCall methodCall) {
    final eventHandlerIntPtr = _irisEventHandler!.address;
    final result = _invokeMethod(
      methodCall.funcName,
      methodCall.params,
      bufferList: [BufferParam(eventHandlerIntPtr, 1)],
    );
    result.data['observerIntPtr'] = eventHandlerIntPtr;
    return result;
  }

  CallApiResult destroyNativeEventHandler(IrisMethodCall methodCall) {
    assert(methodCall.rawBufferParams != null);
    assert(methodCall.rawBufferParams!.length == 1);

    CallApiResult result;
    if (methodCall.funcName.isEmpty) {
      result = CallApiResult(irisReturnCode: 0, data: {'result': 0});
    } else {
      result = _invokeMethod(
        methodCall.funcName,
        methodCall.params,
        bufferList: methodCall.rawBufferParams,
      );
    }

    return result;
  }
}

class BufferParam {
  const BufferParam(this.intPtr, this.length);
  final int intPtr;
  final int length;
}

class ScopedEvent {
  const ScopedEvent({
    required this.scopedKey,
    required this.registerName,
    required this.unregisterName,
    // required this.params,
    required this.handler,
  });
  final TypedScopedKey scopedKey;
  final String registerName;
  final String unregisterName;
  // final String params;
  final EventLoopEventHandler handler;
}

abstract class IrisEventKey {
  const IrisEventKey({
    required this.registerName,
    required this.unregisterName,
  });
  final String registerName;
  final String unregisterName;

  @override
  bool operator ==(Object other) {
    if (other.runtimeType != runtimeType) {
      return false;
    }
    return other is IrisEventKey &&
        other.registerName == registerName &&
        other.unregisterName == unregisterName;
  }

  @override
  int get hashCode => Object.hash(registerName, unregisterName);
}
