import 'package:flutter/material.dart';

class AppColors {
  static const primary = Color(0xFF5BC0BE);
  static const primaryLight = Color(0xFF7AD4D0);
  static const bg = Color(0xFFDAF5F0);
  static const bgStart = Color(0xFFDAF5F0);
  static const bgEnd = Color(0xFFC8EDE8);
  static const text = Color(0xFF3D7068);
  static const textSecondary = Color(0xFF5A9E96);
  static const textMuted = Color(0xFF7AB8AE);
  static const textDim = Color(0xFF9AC8BE);
  static const textDark = Color(0xFF2D5A50);

  static const micActive = Color(0xFFFF6B6B);
  static const micActiveLight = Color(0xFFFF8A8A);
  static const danger = Color(0xFFE74C3C);
  static const failed = Color(0xFFDD5555);
  static const warning = Color(0xFFF39C12);
  static const info = Color(0xFF3498DB);
  static const success = Color(0xFF27AE60);

  static const cardBg = Color(0x66FFFFFF);
  static const cardBgSolid = Color(0xCCFFFFFF);
  static const overlayBg = Color(0x66000000);
  static const divider = Color(0x405BC0BE);

  static const scrollbar = Color(0x665BC0BE);
  static const shadow = Color(0x1A000000);
}

class AppTextStyles {
  static const logo = TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w600,
    color: AppColors.textSecondary,
    letterSpacing: 0.3,
  );

  static const status = TextStyle(fontSize: 11, color: AppColors.textSecondary);

  static const statusActive = TextStyle(
    fontSize: 11,
    color: Colors.white,
    fontWeight: FontWeight.w500,
  );

  static const sectionTitle = TextStyle(
    fontSize: 9,
    color: AppColors.textMuted,
    letterSpacing: 0.5,
  );

  static const micLabel = TextStyle(fontSize: 11, color: AppColors.textMuted);

  static const listHeader = TextStyle(
    fontSize: 12,
    color: AppColors.textSecondary,
    fontWeight: FontWeight.w500,
  );

  static const itemText = TextStyle(fontSize: 12, color: AppColors.text);

  static const emptyState = TextStyle(fontSize: 12, color: AppColors.textDim);

  static const liveEntry = TextStyle(
    fontSize: 12,
    color: AppColors.textSecondary,
    fontStyle: FontStyle.italic,
  );

  static const settingsRow = TextStyle(fontSize: 12, color: AppColors.text);

  static const settingsSection = TextStyle(
    fontSize: 10,
    color: AppColors.textMuted,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.8,
  );

  static const miniTitle = TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.w600,
    color: AppColors.textSecondary,
  );

  static const toast = TextStyle(
    fontSize: 13,
    color: Colors.white,
    fontWeight: FontWeight.w500,
  );

  static const roomLink = TextStyle(
    fontSize: 13,
    color: AppColors.textSecondary,
    fontWeight: FontWeight.w500,
  );

  static const countBadge = TextStyle(
    fontSize: 10,
    color: AppColors.textDark,
    fontWeight: FontWeight.w600,
  );
}

class AppInsets {
  static const headerH = 36.0;
  static const padding = 12.0;
  static const gap = 12.0;
  static const smallGap = 6.0;
  static const leftPanelW = 120.0;
  static const rightPanelW = 140.0;
  static const normalW = 608.0;
  static const normalH = 320.0;

  static const miniW = 280.0;
  static const miniH = 360.0;
  static const miniToolbarH = 30.0;
}

class AppRadius {
  static const pill = 999.0;
  static const normal = 10.0;
  static const card = 6.0;
  static const item = 6.0;
  static const tag = 10.0;
  static const small = 4.0;
  static const round = 50.0;
}

class AppShadows {
  static const card = BoxShadow(
    color: AppColors.shadow,
    blurRadius: 4,
    offset: Offset(0, 1),
  );

  static const elevated = BoxShadow(
    color: AppColors.shadow,
    blurRadius: 8,
    offset: Offset(0, 2),
  );

  static const modal = BoxShadow(
    color: Color(0x26000000),
    blurRadius: 16,
    offset: Offset(0, 4),
  );

  static const mic = BoxShadow(
    color: Color(0x335BC0BE),
    blurRadius: 8,
    offset: Offset(0, 2),
  );
}
