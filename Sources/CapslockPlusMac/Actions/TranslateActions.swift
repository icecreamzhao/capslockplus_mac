import Foundation

enum TranslateActions {
    /// 选中文字 → 浮层显示翻译。再按一次收起。
    static func translateSelection() {
        if TranslatePanel.shared.isVisible {
            TranslatePanel.shared.dismiss()
            Log.info("translate toggle off")
            return
        }

        guard let selected = AX.selectedText() else {
            Log.warn("translate failed reason=no-selection")
            return
        }
        let query = selected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            Log.warn("translate failed reason=empty-selection")
            return
        }
        // 太长的选中内容不翻（整篇文档没意义，也浪费请求）
        guard query.count <= 60 else {
            Log.warn("translate skipped reason=too-long len=\(query.count)")
            TranslatePanel.shared.show(error: "选中的内容太长（\(query.count) 字符），请只选单词或短语")
            return
        }

        Log.info("translate query=\(query)")
        TranslatePanel.shared.showPending(query: query)
        TranslateService.fetch(query) { result in
            switch result {
            case .success(let translation):
                Log.info("translate ok query=\(translation.query) lines=\(translation.lines.count) web=\(translation.webLines.count)")
                TranslatePanel.shared.show(result: translation)
            case .failure(let message):
                Log.warn("translate failed reason=\(message)")
                TranslatePanel.shared.show(error: message)
            }
        }
    }
}
