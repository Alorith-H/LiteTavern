/// 群聊模型与发言轮转（纯逻辑，便于测试）。
///
/// 存储：`groups/<id>.json` = `{id, name, memberIds, createdAt, turnIndex}`。
/// `turnIndex` 是轮转指针 = 下一位发言者在成员列表中的下标，跨轮保留；
/// 只会在「一轮中途被打断」时与 0 产生偏差（完整一轮跑完会绕回原点）。
class ChatGroup {
  final String id;
  final String name;
  final List<String> memberIds;
  final int createdAt;

  /// 轮转指针：下一位发言者的成员下标。
  final int turnIndex;

  /// 发言名单（v0.36.0 群聊主持）：只让名单里的角色发言，顺序按这个列表；
  /// 空列表 = 全员参与（老的轮转行为）。里面存的是角色 id。
  final List<String> speakerIds;

  const ChatGroup({
    required this.id,
    required this.name,
    required this.memberIds,
    required this.createdAt,
    this.turnIndex = 0,
    this.speakerIds = const <String>[],
  });

  factory ChatGroup.fromJson(Map<String, dynamic> json) {
    final ids = (json['memberIds'] as List?)
            ?.whereType<String>()
            .toList() ??
        const <String>[];
    final count = ids.isEmpty ? 1 : ids.length;
    var pointer = (json['turnIndex'] as num?)?.toInt() ?? 0;
    // 防御：成员列表变短后指针可能越界，钳制回合法范围
    pointer = pointer % count;
    if (pointer < 0) pointer += count;
    final speakers = (json['speakerIds'] as List?)
            ?.whereType<String>()
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toList() ??
        const <String>[];
    return ChatGroup(
      id: (json['id'] as String?) ?? '',
      name: (json['name'] as String?) ?? '',
      memberIds: ids,
      createdAt: (json['createdAt'] as num?)?.toInt() ?? 0,
      turnIndex: pointer,
      speakerIds: speakers,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'memberIds': memberIds,
        'createdAt': createdAt,
        'turnIndex': turnIndex,
        if (speakerIds.isNotEmpty) 'speakerIds': speakerIds,
      };

  ChatGroup withTurnIndex(int index) => ChatGroup(
        id: id,
        name: name,
        memberIds: memberIds,
        createdAt: createdAt,
        turnIndex: index,
        speakerIds: speakerIds,
      );

  ChatGroup withSpeakerIds(List<String> ids) => ChatGroup(
        id: id,
        name: name,
        memberIds: memberIds,
        createdAt: createdAt,
        turnIndex: turnIndex,
        speakerIds: List<String>.of(ids),
      );

  /// 当前生效的发言名单（成员下标，按名单顺序；名单为空 → 全员）。
  List<int> speakerIndexes() {
    if (speakerIds.isEmpty) {
      return [for (var i = 0; i < memberIds.length; i++) i];
    }
    final out = <int>[];
    for (final id in speakerIds) {
      final idx = memberIds.indexOf(id);
      if (idx >= 0 && !out.contains(idx)) out.add(idx);
    }
    return out;
  }
}

/// 解析用户消息里的 `@角色名`（名字子串匹配）。
///
/// 返回被 @ 命中的成员下标（按成员列表顺序、去重）；
/// 没有任何命中时返回 null（调用方回退为全员轮转）。
/// 用 `@` 做锚点：`@爱丽丝` 不会命中成员「丽丝」。
Set<int>? parseMentions(String text, List<String> memberNames) {
  final hit = <int>{};
  for (var i = 0; i < memberNames.length; i++) {
    final name = memberNames[i].trim();
    if (name.isEmpty) continue;
    if (text.contains('@$name')) hit.add(i);
  }
  return hit.isEmpty ? null : hit;
}

/// 计算一轮的发言序列（成员下标），返回顺序即生成顺序。
///
/// - [mentioned] 非 null → 仅被 @ 的成员，**严格按群内列表顺序**回复
/// - [mentioned] 为 null → 全员各说一句：从 [turnIndex]（轮转指针）开始
///   绕行一圈。指针跨轮保留：完整一轮跑完回到起点；一轮中途被打断则
///   下次发送从下一成员继续（见 [advanceTurn]）。
List<int> turnOrder(int memberCount, int turnIndex, Set<int>? mentioned) {
  if (memberCount <= 0) return const [];
  final all = [for (var i = 0; i < memberCount; i++) i];
  if (mentioned != null) {
    final subset = all.where(mentioned.contains).toList();
    if (subset.isEmpty) return const [];
    return subset;
  }
  final start = ((turnIndex % memberCount) + memberCount) % memberCount;
  return [...all.sublist(start), ...all.sublist(0, start)];
}

/// 某成员发言后的新指针（下一位发言者）。
int advanceTurn(int memberCount, int spokenIndex) {
  if (memberCount <= 0) return 0;
  return (spokenIndex + 1) % memberCount;
}

/// 按「发言名单」算一轮的发言序列（v0.36.0 群聊主持）。
///
/// [roster] 是允许发言的成员下标（按主持名单顺序）；为空表示全员。
/// [mentioned] 非 null 时只回被 @ 且仍在名单里的成员（按名单顺序）；
/// 否则从 [turnIndex]（成员下标）起在名单内轮转一圈。
List<int> hostedTurnOrder(
  int memberCount,
  List<int> roster,
  int turnIndex,
  Set<int>? mentioned,
) {
  if (memberCount <= 0) return const [];
  var allowed = roster.isEmpty
      ? [for (var i = 0; i < memberCount; i++) i]
      : roster.where((i) => i >= 0 && i < memberCount).toList();
  if (allowed.isEmpty) allowed = [for (var i = 0; i < memberCount; i++) i];
  if (mentioned != null) {
    final picked = allowed.where(mentioned.contains).toList();
    return picked.isEmpty ? const [] : picked;
  }
  final pos = allowed.indexOf(turnIndex);
  final start = pos < 0 ? 0 : pos;
  return [...allowed.sublist(start), ...allowed.sublist(0, start)];
}

/// 名单里某成员发言后的下一位（成员下标）；名单为空时退回全员轮转。
int advanceHostTurn(int memberCount, List<int> roster, int spokenIndex) {
  if (memberCount <= 0) return 0;
  final allowed = roster.isEmpty
      ? [for (var i = 0; i < memberCount; i++) i]
      : roster.where((i) => i >= 0 && i < memberCount).toList();
  if (allowed.isEmpty) return advanceTurn(memberCount, spokenIndex);
  final pos = allowed.indexOf(spokenIndex);
  if (pos < 0) return allowed.first;
  return allowed[(pos + 1) % allowed.length];
}
