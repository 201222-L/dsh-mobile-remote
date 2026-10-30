// 首页背景里的「大肥鱼」角色：点击头部/身体/尾巴有不同反应，长按开迷你面板。
// 动作用原生服务同源的宠物动画（animated WebP）；减少动效时退回静态帧。
import 'dart:async';

import 'package:flutter/material.dart';

import '../store.dart';
import '../theme.dart';
import 'session_indicator.dart';

class HomePet extends StatefulWidget {
  const HomePet({
    super.key,
    required this.store,
    this.height = 132,
    this.onLongPress,
  });

  final AppStore store;

  /// 首页固定尺寸，和「桌面宠物大小」设置无关；改这里即可整体缩放。
  final double height;
  final VoidCallback? onLongPress;

  @override
  State<HomePet> createState() => _HomePetState();
}

class _HomePetState extends State<HomePet> {
  String _clip = 'idle';
  String? _line;
  Timer? _timer;

  static const _lines = {
    'idle': '今天想设计点什么？',
    'pat': '嘿嘿，摸头收到～',
    'poke': '诶？我在呢！',
    'tail': '尾巴不能乱拉啦！',
  };

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _react(String clip) {
    setState(() {
      _clip = clip;
      _line = _lines[clip];
    });
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 1800), () {
      if (!mounted) return;
      setState(() {
        _clip = 'idle';
        _line = null;
      });
    });
  }

  void _handleTap(TapUpDetails d, double h) {
    final y = d.localPosition.dy / h;
    if (y < 0.5) {
      _react('pat');
    } else if (y > 0.84) {
      _react('tail');
    } else {
      _react('poke');
    }
  }

  @override
  Widget build(BuildContext context) {
    final reduced = prefersReducedMotion(context) || widget.store.petReducedMotion;
    final asset = reduced
        ? 'assets/pet/static-${_clip == 'pat' ? 'head_pat' : _clip == 'poke' ? 'poke' : _clip == 'tail' ? 'tail' : 'idle'}.png'
        : 'assets/pet/${_clip == 'pat' ? 'head_pat' : _clip == 'poke' ? 'poke' : _clip == 'tail' ? 'tail' : 'idle'}.webp';
    final bubble = _line;
    final bubbleBg = DshColors.surface(context).withValues(alpha: 0.92);
    return SizedBox(
      // 画布宽高比 412:327，留一点气泡余量
      width: widget.height * 1.32,
      height: widget.height + 42,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.bottomCenter,
        children: [
          // 脚下潮光
          Positioned(
            bottom: -2,
            child: Container(
              width: widget.height * 0.72,
              height: 16,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(99),
                gradient: RadialGradient(
                  colors: [
                    DshColors.glow(context).withValues(alpha: 0.28),
                    DshColors.glow(context).withValues(alpha: 0),
                  ],
                ),
              ),
            ),
          ),
          if (bubble != null)
            Positioned(
              top: 0,
              child: AnimatedOpacity(
                opacity: 1,
                duration: const Duration(milliseconds: 160),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                  decoration: BoxDecoration(
                    color: bubbleBg,
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: DshColors.brand(context).withValues(alpha: 0.35)),
                    boxShadow: DshTheme.shadow,
                  ),
                  child: Text(
                    bubble,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: DshColors.ink(context),
                    ),
                  ),
                ),
              ),
            ),
          Positioned(
            bottom: 0,
            child: Semantics(
              label: '大肥鱼',
              button: true,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapUp: (d) => _handleTap(d, widget.height),
                onLongPress: () {
                  _react('pat');
                  widget.onLongPress?.call();
                },
                child: Image.asset(
                  asset,
                  height: widget.height,
                  fit: BoxFit.contain,
                  gaplessPlayback: true,
                  filterQuality: FilterQuality.medium,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
