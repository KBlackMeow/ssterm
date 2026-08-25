import 'package:flutter_test/flutter_test.dart';
import 'package:ssterm/services/agent_decision_policy.dart';
import 'package:ssterm/services/agent_decision_transcript.dart';

void main() {
  const plan = AgentDecisionPlan(
    recommendedId: 'a',
    candidates: [
      AgentDecisionCandidate(
        id: 'a',
        summary: '稳妥方案',
        fit: '适合现有环境',
        evidence: '已有检查结果支持',
        cost: '低',
        maintenance: '低',
        risk: '依赖服务可用性',
        validation: '运行检查',
      ),
      AgentDecisionCandidate(
        id: 'b',
        summary: '快速方案',
        fit: '适合短期验证',
        evidence: '需要额外确认',
        cost: '中',
        maintenance: '中',
        risk: '回滚成本较高',
        validation: '人工复核',
      ),
    ],
  );

  test('planning formats parsed candidates without raw JSON', () {
    final text = AgentDecisionTranscript.planning(plan);

    expect(text, contains('已完成方案梳理'));
    expect(text, contains('方案 a：稳妥方案'));
    expect(text, contains('方案 b：快速方案'));
    expect(text, contains('风险：依赖服务可用性'));
    expect(text, isNot(contains('recommendedId')));
  });

  test('recommendation identifies the selected candidate and validation', () {
    final text = AgentDecisionTranscript.recommendation(plan);

    expect(text, contains('建议采用：稳妥方案'));
    expect(text, contains('依据：已有检查结果支持'));
    expect(text, contains('验证方式：运行检查'));
  });
}
