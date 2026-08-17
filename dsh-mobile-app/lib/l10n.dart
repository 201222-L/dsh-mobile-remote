// 轻量 i18n（v2.7）：全局语言状态 + 双语查表。
// 用法：L10n.t('中文', 'English') —— lang 为 'en' 时返回英文，否则中文。
// 语言状态由 AppStore.setLanguage 维护（持久化）；纯文本控件用 t() 即可，
// 需要随语言重建的页面在 build 里直接读 L10n.lang（store 变更会 notify 重建）。
class L10n {
  static String lang = 'zh'; // 'zh' | 'en'

  static String t(String zh, [String? en]) => lang == 'en' ? (en ?? zh) : zh;
}
