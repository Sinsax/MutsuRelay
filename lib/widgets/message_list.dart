import 'dart:math' show pi;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/sentence_item.dart';
import '../providers/app_state.dart';
import '../theme/app_theme.dart';

class MessageList extends StatefulWidget {
  const MessageList({super.key});

  @override
  State<MessageList> createState() => _MessageListState();
}

class _MessageListState extends State<MessageList> with TickerProviderStateMixin {
  final _scrollController = ScrollController();
  final _editController = TextEditingController();
  final _manualController = TextEditingController();
  int? _prevEditId;

  @override
  void initState() {
    super.initState();
    _editController.addListener(_onEditChanged);
  }

  void _onEditChanged() {
    final state = context.read<AppState>();
    if (state.editingId != null) {
      state.setEditText(_editController.text);
    }
  }

  @override
  void dispose() {
    _editController.removeListener(_onEditChanged);
    _scrollController.dispose();
    _editController.dispose();
    _manualController.dispose();
    super.dispose();
  }

  void _syncEditController(AppState state) {
    if (state.editingId != null && _prevEditId != state.editingId) {
      _editController.text = state.editText;
      _prevEditId = state.editingId;
    } else if (state.editingId == null) {
      _prevEditId = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Selector<AppState, ({WindowMode windowMode, bool invertMiniText, bool isConnected, bool cookieStatus, List<SentenceItem> sentenceList, String liveText, bool isRecording, int pendingCount, int? editingId, String editText, String manualInput})>(
      selector: (_, state) => (
        windowMode: state.windowMode,
        invertMiniText: state.invertMiniText,
        isConnected: state.isConnected,
        cookieStatus: state.cookieStatus,
        sentenceList: state.sentenceList,
        liveText: state.liveText,
        isRecording: state.isRecording,
        pendingCount: state.pendingCount,
        editingId: state.editingId,
        editText: state.editText,
        manualInput: state.manualInput,
      ),
      builder: (context, data, _) {
        final state = context.read<AppState>();
        _syncEditController(state);
        final isMini = data.windowMode == WindowMode.mini;
        if (isMini) {
          return _miniLayout(data);
        }
        return _normalLayout(data);
      },
    );
  }

  Widget _normalLayout((
    {WindowMode windowMode,
    bool invertMiniText,
    bool isConnected,
    bool cookieStatus,
    List<SentenceItem> sentenceList,
    String liveText,
    bool isRecording,
    int pendingCount,
    int? editingId,
    String editText,
    String manualInput}
  ) data) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0x80FFFFFF),
        borderRadius: BorderRadius.circular(AppRadius.normal),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          _header(data, mini: false, invert: false),
          Expanded(child: _listBody(data, false, invert: false)),
          _manualInput(data, false, invert: false),
        ],
      ),
    );
  }

  Widget _miniLayout((
    {WindowMode windowMode,
    bool invertMiniText,
    bool isConnected,
    bool cookieStatus,
    List<SentenceItem> sentenceList,
    String liveText,
    bool isRecording,
    int pendingCount,
    int? editingId,
    String editText,
    String manualInput}
  ) data) {
    final invert = data.invertMiniText;
    return Column(
      children: [
        _header(data, mini: true, invert: invert),
        Expanded(child: _listBody(data, true, invert: invert)),
        _manualInput(data, true, invert: invert),
      ],
    );
  }

  Widget _header((
    {WindowMode windowMode,
    bool invertMiniText,
    bool isConnected,
    bool cookieStatus,
    List<SentenceItem> sentenceList,
    String liveText,
    bool isRecording,
    int pendingCount,
    int? editingId,
    String editText,
    String manualInput}
  ) data, {bool mini = false, bool invert = false}) {
    final state = context.read<AppState>();
    final isEmpty = data.sentenceList.isEmpty;
    return Container(
      padding: EdgeInsets.symmetric(horizontal: mini ? 10 : 12, vertical: mini ? 4 : 8),
      decoration: BoxDecoration(
        color: mini ? const Color(0x66FFFFFF) : (invert ? const Color(0x335BC0BE) : const Color(0x66FFFFFF)),
        border: Border(
          bottom: BorderSide(
            color: mini ? const Color(0x265BC0BE) : (invert ? const Color(0x4D5BC0BE) : AppColors.divider),
            width: 1,
          ),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '消息列表(${data.pendingCount}/${data.sentenceList.length})',
              style: mini
                  ? AppTextStyles.listHeader.copyWith(fontSize: 11, color: invert ? AppColors.textDark : Colors.white, fontWeight: FontWeight.w600, shadows: invert ? const [Shadow(color: Color(0x60FFFFFF), blurRadius: 4, offset: Offset(0, 1))] : const [Shadow(color: Color(0x80000000), blurRadius: 4, offset: Offset(0, 1))])
                  : (invert ? AppTextStyles.listHeader.copyWith(color: Colors.white) : AppTextStyles.listHeader),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(AppRadius.small),
              onTap: isEmpty ? null : () => state.clearList(),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  border: Border.all(
                    color: isEmpty
                        ? const Color(0x4D5BC0BE).withValues(alpha: 0.3)
                        : const Color(0x4D5BC0BE),
                  ),
                  borderRadius: BorderRadius.circular(AppRadius.small),
                ),
                child: Text(
                  '清空',
                  style: TextStyle(
                    fontSize: 10,
                    color: isEmpty
                        ? AppColors.textDim.withValues(alpha: 0.3)
                        : (mini ? (invert ? AppColors.textDark : Colors.white) : (invert ? Colors.white : AppColors.textMuted)),
                    fontWeight: mini ? FontWeight.w600 : FontWeight.normal,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _listBody((
    {WindowMode windowMode,
    bool invertMiniText,
    bool isConnected,
    bool cookieStatus,
    List<SentenceItem> sentenceList,
    String liveText,
    bool isRecording,
    int pendingCount,
    int? editingId,
    String editText,
    String manualInput}
  ) data, bool mini, {bool invert = false}) {
    final hasLive = data.liveText.isNotEmpty && data.isRecording;
    final isEmpty = data.sentenceList.isEmpty && !hasLive;

    if (isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.forum_outlined,
              size: mini ? 24 : 32,
              color: AppColors.textDim.withValues(alpha: 0.5),
            ),
            const SizedBox(height: 8),
            Text(
              '暂无消息',
              style: mini
                  ? AppTextStyles.emptyState.copyWith(color: invert ? AppColors.textDark : Colors.white, fontWeight: FontWeight.w500, shadows: invert ? const [Shadow(color: Color(0x60FFFFFF), blurRadius: 4, offset: Offset(0, 1))] : const [Shadow(color: Color(0x80000000), blurRadius: 4, offset: Offset(0, 1))])
                  : AppTextStyles.emptyState,
            ),
          ],
        ),
      );
    }

    return ScrollConfiguration(
      behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
      child: Scrollbar(
        controller: _scrollController,
        thumbVisibility: mini,
        trackVisibility: mini,
        thickness: 4,
        radius: const Radius.circular(2),
        child: ListView.builder(
          controller: _scrollController,
          padding: EdgeInsets.all(mini ? 4 : 8),
          itemCount: (hasLive ? 1 : 0) + data.sentenceList.length,
          itemBuilder: (context, index) {
            if (hasLive && index == 0) {
              return RepaintBoundary(
                child: _liveEntry(data.liveText, mini, invert: invert),
              );
            }
            final itemIndex = hasLive ? index - 1 : index;
            final item = data.sentenceList[itemIndex];
            return _listItem(data, item, mini, invert: invert, key: ValueKey(item.id));
          },
        ),
      ),
    );
  }

  Widget _liveEntry(String text, bool mini, {bool invert = false}) {
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: EdgeInsets.symmetric(horizontal: mini ? 8 : 10, vertical: mini ? 4 : 6),
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: AppColors.primary, width: 3)),
      ),
      child: Text(
        text,
        style: mini
            ? AppTextStyles.liveEntry.copyWith(fontSize: 11, color: invert ? AppColors.textDark : Colors.white, fontWeight: FontWeight.w500, shadows: invert ? const [Shadow(color: Color(0x60FFFFFF), blurRadius: 4, offset: Offset(0, 1))] : const [Shadow(color: Color(0x80000000), blurRadius: 4, offset: Offset(0, 1))])
            : AppTextStyles.liveEntry,
      ),
    );
  }

  Widget _listItem((
    {WindowMode windowMode,
    bool invertMiniText,
    bool isConnected,
    bool cookieStatus,
    List<SentenceItem> sentenceList,
    String liveText,
    bool isRecording,
    int pendingCount,
    int? editingId,
    String editText,
    String manualInput}
  ) data, SentenceItem item, bool mini, {bool invert = false, Key? key}) {
    final state = context.read<AppState>();
    final isEditing = data.editingId == item.id;

    Color borderColor;
    Color bgColor;
    Color iconColor;
    double opacity;

    switch (item.status) {
      case SentenceStatus.pending:
        borderColor = const Color(0xFFA5CEC5);
        bgColor = const Color(0x66FFFFFF);
        iconColor = borderColor;
        opacity = 1.0;
      case SentenceStatus.sending:
        borderColor = AppColors.textSecondary;
        bgColor = const Color(0x265BC0BE);
        iconColor = borderColor;
        opacity = 1.0;
      case SentenceStatus.success:
        borderColor = AppColors.textSecondary;
        bgColor = const Color(0x66FFFFFF);
        iconColor = borderColor;
        opacity = 0.45;
      case SentenceStatus.failed:
        borderColor = const Color(0xFFDD5555);
        bgColor = const Color(0x4DFFB4B4);
        iconColor = const Color(0xFFDD5555);
        opacity = 1.0;
    }

    if (mini) {
      bgColor = Colors.transparent;
    }

    return Opacity(
      opacity: opacity,
      child: Container(
        margin: EdgeInsets.only(bottom: mini ? 2 : 4),
        padding: EdgeInsets.symmetric(horizontal: mini ? 8 : 10, vertical: mini ? 4 : 6),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(mini ? 4 : AppRadius.item),
          border: Border(left: BorderSide(color: borderColor, width: 3)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _itemIcon(item.status, iconColor, mini),
            const SizedBox(width: 6),
            if (isEditing)
              Expanded(
                child: SizedBox(
                  height: 24,
                  child: TextField(
                    controller: _editController,
                    onSubmitted: (_) => state.saveEdit(item.id),
                    style: const TextStyle(fontSize: 12, color: AppColors.text),
                    decoration: const InputDecoration(
                      contentPadding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.all(Radius.circular(4)),
                        borderSide: BorderSide(color: AppColors.primary),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.all(Radius.circular(4)),
                        borderSide: BorderSide(color: AppColors.primary),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.all(Radius.circular(4)),
                        borderSide: BorderSide(color: AppColors.primary, width: 2),
                      ),
                    ),
                  ),
                ),
              )
            else
              Expanded(
                child: Text(
                  item.text,
                  style: TextStyle(
                    fontSize: mini ? 11 : 12,
                    color: mini ? (invert ? AppColors.textDark : Colors.white) : AppColors.text,
                    fontWeight: mini ? FontWeight.w600 : null,
                    decoration: item.isSuccess ? TextDecoration.lineThrough : null,
                    shadows: mini ? (invert ? const [Shadow(color: Color(0x60FFFFFF), blurRadius: 4, offset: Offset(0, 1))] : const [Shadow(color: Color(0x80000000), blurRadius: 4, offset: Offset(0, 1))]) : null,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            const SizedBox(width: 6),
            if (!item.isSuccess) ...[
              _actionBtn('发', () => state.sendItem(item.id),
                  mini ? (invert ? AppColors.textDark : Colors.white) : AppColors.textDark,
                  mini ? (invert ? AppColors.textDark : Colors.white) : AppColors.primary,
                  item.isSending || !data.isConnected, mini),
              _actionBtn('编', () => state.startEdit(item.id, item.text),
                  mini ? (invert ? AppColors.textDark : Colors.white) : AppColors.textSecondary,
                  mini ? (invert ? AppColors.textDark : Colors.white) : AppColors.primary, false, mini),
            ],
            _actionBtn('×', () => state.deleteItem(item.id),
                mini ? (invert ? AppColors.textDark : Colors.white) : AppColors.failed,
                mini ? (invert ? AppColors.textDark : Colors.white) : AppColors.danger, false, mini),
          ],
        ),
      ),
    );
  }

  Widget _itemIcon(SentenceStatus status, Color color, bool mini) {
    if (status == SentenceStatus.sending) {
      return _SpinWidget(
        color: color,
        size: mini ? 10 : 11,
      );
    }
    String text;
    switch (status) {
      case SentenceStatus.success:
        text = '✓';
      case SentenceStatus.failed:
        text = '✗';
      case SentenceStatus.sending:
        text = '⏳';
      case SentenceStatus.pending:
        text = '●';
    }
    return SizedBox(
      width: 14,
      child: Text(text, style: TextStyle(fontSize: mini ? 10 : 11, color: color), textAlign: TextAlign.center),
    );
  }

  Widget _actionBtn(String label, VoidCallback onTap, Color color, Color hoverColor, bool disabled, bool mini) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(3),
        onTap: disabled ? null : onTap,
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: mini ? 4 : 5, vertical: 1),
          margin: const EdgeInsets.only(left: 2),
          decoration: BoxDecoration(
            border: Border.all(color: color.withValues(alpha: disabled ? 0.4 : 0.4)),
            borderRadius: BorderRadius.circular(3),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: mini ? 9 : 10,
              color: disabled ? color.withValues(alpha: 0.4) : color,
            ),
          ),
        ),
      ),
    );
  }

  Widget _manualInput((
    {WindowMode windowMode,
    bool invertMiniText,
    bool isConnected,
    bool cookieStatus,
    List<SentenceItem> sentenceList,
    String liveText,
    bool isRecording,
    int pendingCount,
    int? editingId,
    String editText,
    String manualInput}
  ) data, bool mini, {bool invert = false}) {
    final state = context.read<AppState>();
    final canSend = data.manualInput.trim().isNotEmpty &&
        data.isConnected &&
        data.cookieStatus;

    return Container(
      padding: EdgeInsets.all(mini ? 4 : 8),
      decoration: BoxDecoration(
        color: mini ? Colors.transparent : (invert ? const Color(0x335BC0BE) : const Color(0x66FFFFFF)),
        border: Border(
          top: BorderSide(
            color: mini ? const Color(0x265BC0BE) : (invert ? const Color(0x4D5BC0BE) : AppColors.divider),
            width: 1,
          ),
        ),
      ),
      child: Row(
        children: [
            Expanded(
              child: SizedBox(
                height: mini ? 22 : 30,
                child: TextField(
                  controller: _manualController,
                  onChanged: (v) => state.manualInput = v,
                  onSubmitted: (_) => state.sendManualMessage(),
                  style: TextStyle(
                    fontSize: mini ? 11 : 12,
                    color: mini ? (invert ? AppColors.textDark : Colors.white) : AppColors.text,
                    fontWeight: mini ? FontWeight.w600 : null,
                    shadows: mini ? (invert ? const [Shadow(color: Color(0x60FFFFFF), blurRadius: 4, offset: Offset(0, 1))] : const [Shadow(color: Color(0x80000000), blurRadius: 4, offset: Offset(0, 1))]) : null,
                  ),
                  decoration: InputDecoration(
                    hintText: '输入弹幕...',
                    hintStyle: TextStyle(
                      color: mini ? (invert ? AppColors.textDark.withValues(alpha: 0.6) : Colors.white.withValues(alpha: 0.6)) : (invert ? Colors.white.withValues(alpha: 0.6) : AppColors.textDim),
                      fontSize: mini ? 11 : 12,
                      shadows: mini ? (invert ? [const Shadow(color: Color(0x60FFFFFF), blurRadius: 3, offset: Offset(0, 1))] : [const Shadow(color: Color(0x80000000), blurRadius: 3, offset: Offset(0, 1))]) : null,
                    ),
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: mini ? 8 : 10,
                      vertical: mini ? 4 : 6,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(mini ? 4 : AppRadius.card),
                      borderSide: const BorderSide(color: Color(0x665BC0BE)),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(mini ? 4 : AppRadius.card),
                      borderSide: BorderSide(
                        color: data.isConnected && data.cookieStatus
                            ? const Color(0x665BC0BE)
                            : const Color(0x665BC0BE).withValues(alpha: 0.4),
                      ),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(mini ? 4 : AppRadius.card),
                      borderSide: const BorderSide(color: AppColors.primary, width: 1.5),
                    ),
                  ),
                  enabled: data.isConnected && data.cookieStatus,
                ),
              ),
            ),
          const SizedBox(width: 6),
          _sendBtn(canSend, mini, state),
        ],
      ),
    );
  }

  Widget _sendBtn(bool canSend, bool mini, AppState state) {
    return Material(
      color: canSend ? AppColors.primary : AppColors.primary.withValues(alpha: 0.4),
      borderRadius: BorderRadius.circular(mini ? 4 : AppRadius.card),
      child: InkWell(
        borderRadius: BorderRadius.circular(mini ? 4 : AppRadius.card),
        onTap: canSend ? () => state.sendManualMessage() : null,
        hoverColor: AppColors.primaryLight,
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: mini ? 10 : 14, vertical: mini ? 4 : 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.send_rounded, size: 12, color: canSend ? Colors.white : Colors.white.withValues(alpha: 0.5)),
              const SizedBox(width: 4),
              Text(
                '发送',
                style: TextStyle(
                  fontSize: mini ? 11 : 11,
                  color: canSend ? Colors.white : Colors.white.withValues(alpha: 0.5),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SpinWidget extends StatefulWidget {
  final Color color;
  final double size;
  const _SpinWidget({required this.color, required this.size});

  @override
  State<_SpinWidget> createState() => _SpinWidgetState();
}

class _SpinWidgetState extends State<_SpinWidget> with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _controller.repeat();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Transform.rotate(
          angle: _controller.value * 2 * pi,
          child: SizedBox(
            width: 14,
            child: Text(
              '⏳',
              style: TextStyle(fontSize: widget.size, color: widget.color),
              textAlign: TextAlign.center,
            ),
          ),
        );
      },
    );
  }
}
