import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:litetavern/models/chat_message.dart';
import 'package:litetavern/services/active_generations.dart';
import 'package:litetavern/services/prompt_builder.dart';
import 'package:litetavern/services/sampling_params.dart';
import 'package:litetavern/services/storage.dart';

/// v0.10.0 后台生成管理器：注册/解绑不取消、完成落库、重进接管。
/// runner 全部注入假流（GenerationRunner），与 v9 同一风格直接打 API。

GenRequest _req() => const GenRequest(
      baseUrl: 'http://test',
      apiKey: 'k',
      model: 'm',
      messages: [PromptMessage(role: 'user', content: '你好')],
      temperature: 0.8,
      topP: 1.0,
      maxTokens: 0,
      stream: true,
      sampling: SamplingParams(),
    );

/// 播种一条会话：user + 空的 assistant 占位（ts 为目标时间戳）。
Future<void> _seed(String key, int ts) => Storage.saveConversation(key, [
      const ChatMessage(role: 'user', content: '你好', timestamp: 1),
      ChatMessage(role: 'assistant', content: '', timestamp: ts),
    ]);

void main() {
  final mgr = ActiveGenerations.instance;

  setUp(() {
    final docs = Directory.systemTemp.createTempSync('litetavern_v10_test');
    Storage.initForTest(docs);
    Directory('${docs.path}/conversations').createSync(recursive: true);
    mgr.debugReset();
  });

  // -------------------------------------------- 注册/解绑不取消 --
  group('注册/解绑不取消：dispose 只 detach，请求后台跑完', () {
    test('detach 后任务不结束不取消，增量照进权威缓冲，收尾才出册', () async {
      final gate = Completer<void>();
      final job = mgr.start(
        key: 'k1',
        kind: GenKind.chat,
        request: _req(),
        targetTs: null,
        runner: (j) async {
          j.emitDelta('1');
          await gate.future;
          j.emitDelta('2');
        },
      );
      expect(job, isNotNull);
      expect(mgr.has('k1'), isTrue); // 已注册

      job!.detach(); // 页面 dispose：只解绑 UI 监听
      expect(job.done, isFalse);
      expect(job.cancelled, isFalse); // 没有被取消
      expect(mgr.has('k1'), isTrue); // 仍在册
      expect(job.fullText, '1'); // detach 前的增量已入缓冲

      gate.complete();
      await job.finished;
      expect(job.done, isTrue);
      expect(job.cancelled, isFalse); // 全程未取消，正常跑完
      expect(job.fullText, '12'); // 解绑期间的增量照常累积
      expect(mgr.has('k1'), isFalse); // 收尾后才移出任务表
    });

    test('解绑期间错误/usage 照常记账，完成信号只走 finished', () async {
      final gate = Completer<void>();
      final job = mgr.start(
        key: 'k2',
        kind: GenKind.chat,
        request: _req(),
        targetTs: null,
        runner: (j) async {
          j.emitDelta('A');
          await gate.future;
          j.emitError('超时了');
          j.emitUsage(10, 20);
          j.emitDelta('B');
        },
      )!;
      job.detach();
      expect(job.error, isNull); // 错误还没发生

      gate.complete();
      await job.finished;
      expect(job.done, isTrue);
      expect(job.cancelled, isFalse);
      expect(job.error, '超时了'); // 解绑后错误仍记录在任务上
      expect(job.exactPrompt, 10);
      expect(job.exactCompletion, 20);
      expect(job.fullText, 'AB');
      expect(mgr.has('k2'), isFalse);
    });
  });

  // ------------------------------------------------ 完成落库 --
  group('完成落库：页面已关也写入会话文件', () {
    test('从未绑定页面 → 完成后目标消息写入权威全文', () async {
      await _seed('c1', 100);
      final job = mgr.start(
        key: 'c1',
        kind: GenKind.chat,
        request: _req(),
        initialText: '',
        targetTs: 100,
        runner: (j) async {
          j.emitDelta('你好');
          j.emitDelta('，世界');
        },
      )!;
      // 没有任何 attach/detach —— 页面自始至终不在
      await job.finished;

      final data = await Storage.loadConversationData('c1');
      expect(data.messages, hasLength(2));
      expect(data.messages.last.role, 'assistant');
      expect(data.messages.last.timestamp, 100);
      expect(data.messages.last.content, '你好，世界');
      expect(data.messages.first.content, '你好'); // user 消息不受影响
      expect(mgr.has('c1'), isFalse);
    });

    test('绑定过又解绑（页面中途销毁）→ 完成仍落库，文本不缺段', () async {
      await _seed('c2', 200);
      final gate = Completer<void>();
      final job = mgr.start(
        key: 'c2',
        kind: GenKind.chat,
        request: _req(),
        initialText: '',
        targetTs: 200,
        onDelta: (_) {}, // 发起页绑定过
        runner: (j) async {
          j.emitDelta('前半');
          await gate.future;
          j.emitDelta('后半');
        },
      )!;
      job.detach(); // 页面销毁
      gate.complete();
      await job.finished;

      final data = await Storage.loadConversationData('c2');
      expect(data.messages.last.content, '前半后半');
    });

    test('目标占位已不在（会话被清空）→ 完成不写，不复活旧内容', () async {
      // 目标 ts=300 的占位在"清空"后消失：文件里只剩 user 消息
      await Storage.saveConversation('c3', [
        const ChatMessage(role: 'user', content: '你好', timestamp: 1),
      ]);
      final job = mgr.start(
        key: 'c3',
        kind: GenKind.chat,
        request: _req(),
        initialText: '旧内容',
        targetTs: 300,
        runner: (j) async {
          j.emitDelta('幽灵文本');
        },
      )!;
      await job.finished;

      final data = await Storage.loadConversationData('c3');
      expect(data.messages, hasLength(1)); // 没有被写回/复活
      expect(data.messages.single.role, 'user');
    });
  });

  // ------------------------------------------------ 重进接管 --
  group('重进接管：detach 后重新 attach 继续显示', () {
    test('接管后收到后续增量，完成触发 onDone，全文以任务缓冲为准', () async {
      final gate = Completer<void>();
      final job = mgr.start(
        key: 'r1',
        kind: GenKind.chat,
        request: _req(),
        targetTs: null,
        runner: (j) async {
          j.emitDelta('1');
          await gate.future;
          j.emitDelta('2');
          j.emitUsage(5, 7);
        },
      )!;

      job.detach(); // —— 退出页面 ——

      // —— 重进页面：attach 接管显示 ——
      final deltas = <String>[];
      GenerationJob? doneJob;
      job.attach(
        onDelta: deltas.add,
        onError: (_) {},
        onDone: (j) => doneJob = j,
      );

      gate.complete();
      await job.finished;

      expect(deltas, ['2']); // 只收接管后的新增量（旧的靠 fullText 同步）
      expect(job.fullText, '12'); // 权威缓冲完整
      expect(doneJob, same(job)); // 完成移交回调到达接管页
      expect(job.exactCompletion, 7);
      expect(mgr.has('r1'), isFalse);
    });
  });

  // ------------------------------------------------ 防重入 --
  group('同 key 防重入：生成中禁止重复发起', () {
    test('进行中 start 返回 null；结束后同 key 可再发起', () async {
      final gate = Completer<void>();
      final job1 = mgr.start(
        key: 'dup',
        kind: GenKind.chat,
        request: _req(),
        targetTs: null,
        runner: (j) async => gate.future,
      );
      expect(job1, isNotNull);

      final job2 = mgr.start(
        key: 'dup',
        kind: GenKind.chat,
        request: _req(),
        targetTs: null,
        runner: (j) async {},
      );
      expect(job2, isNull); // 拒绝重复发起
      expect(identical(mgr.of('dup'), job1), isTrue);

      gate.complete();
      await job1!.finished;

      final job3 = mgr.start(
        key: 'dup',
        kind: GenKind.chat,
        request: _req(),
        targetTs: null,
        runner: (j) async {},
      );
      expect(job3, isNotNull); // 任务结束后放行
      await job3!.finished;
      expect(mgr.has('dup'), isFalse);
    });
  });
}
