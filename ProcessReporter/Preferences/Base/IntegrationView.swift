//
//  IntegrationView.swift
//  ProcessReporter
//
//  Created by Innei on 2025/4/8.
//

import Cocoa

@MainActor
class IntegrationView: NSView {
    lazy var gridView: NSGridView = {
        let gridView = NSGridView()
        gridView.rowSpacing = 12
        gridView.columnSpacing = 12
        return gridView
    }()

    func setupUI() {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.hasHorizontalScroller = false
        let documentView = NSView()
        documentView.addSubview(gridView)
        scrollView.documentView = documentView
        addSubview(scrollView)

        // 确保 scrollView 填满父视图
        scrollView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        // 设置 documentView 的约束，确保它至少填满 scrollView 的宽度
        documentView.snp.makeConstraints { make in
            make.width.equalTo(scrollView.snp.width) // 宽度与 scrollView 一致
            make.top.equalToSuperview() // 顶部对齐
            make.bottom.greaterThanOrEqualTo(scrollView.snp.bottom) // 确保高度至少填满 scrollView
        }

        // 设置 gridView 的约束，确保它顶部对齐且水平居中
        gridView.snp.makeConstraints { make in
            make.top.equalToSuperview().offset(20) // 顶部对齐并偏移 20
            make.centerX.equalToSuperview() // 水平居中
            make.width.lessThanOrEqualToSuperview().inset(40) // 宽度约束
            make.bottom.lessThanOrEqualToSuperview().inset(20) // 确保底部有边界
        }

        documentView.wantsLayer = true
        scrollView.backgroundColor = NSColor.windowBackgroundColor
    }

    func createRow(leftView: NSView, rightView: NSView) {
        gridView.addRow(with: [leftView, rightView])
        if let cell = gridView.cell(for: leftView) {
            cell.xPlacement = .trailing
            cell.yPlacement = .center
        }
        leftView.snp.makeConstraints { make in
            make.width.lessThanOrEqualTo(120)
        }

        // 设置右侧控件的宽度约束
        if rightView is NSTextField {
            rightView.snp.makeConstraints { make in
                make.width.greaterThanOrEqualTo(200)
            }
        } else if rightView is NSPopUpButton {
            rightView.snp.makeConstraints { make in
                make.width.equalTo(120)
            }
        }
        rightView.snp.makeConstraints { make in
            make.height.greaterThanOrEqualTo(22)
        }
    }

    func createRowDescription(attributedText: NSAttributedString) {
        let label = NSTextField(labelWithAttributedString: attributedText)

        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: 12)
        label.isSelectable = true
        label.isEditable = false
        label.allowsEditingTextAttributes = true

        gridView.addRow(with: [NSView(), label])
    }

    func createRowDescription(text: String) {
        let label = NSTextField(labelWithString: text)
        label.textColor = .secondaryLabelColor
        label.isSelectable = true
        label.font = .systemFont(ofSize: 12)
        label.sizeToFit()
        label.lineBreakMode = .byWordWrapping
        gridView.addRow(with: [NSView(), label])

        label.snp.makeConstraints { make in
            make.width.lessThanOrEqualTo(200)
        }
    }
}
