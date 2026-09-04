import SwiftUI

/// 首次配对 6 位 PIN 码输入浮层 (支持动态校验、输入满 6 位自动确认、丝滑退格删除)
struct PairingSheet: View {
    @Binding var isPresented: Bool
    @State private var fullPinText: String = ""
    @FocusState private var isFieldFocused: Bool
    @State private var isVerifying: Bool = false
    @State private var errorMessage: String? = nil
    @State private var isSuccess: Bool = false
    @State private var shakeOffset: CGFloat = 0

    var onPaired: ((String) -> Void)?

    init(isPresented: Binding<Bool>, onPaired: ((String) -> Void)? = nil) {
        self._isPresented = isPresented
        self.onPaired = onPaired
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // 图标与引导说明
                    VStack(spacing: 10) {
                        Image(systemName: isSuccess ? "checkmark.shield.fill" : "lock.shield.fill")
                            .font(.system(size: 48))
                            .foregroundStyle(
                                isSuccess
                                    ? AnyShapeStyle(Color.green)
                                    : AnyShapeStyle(LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                            )
                            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isSuccess)
                            .padding(.top, 16)

                        Text(isSuccess ? "配对验证成功！" : "安全信任配对")
                            .font(.title3.bold())

                        Text("请输入 Windows 电脑托盘浮窗中显示的\n 6 位安全配对码，以建立端到端加密通道")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 16)
                    }

                    // 6 位数字方框输入组件
                    ZStack {
                        // 底层隐藏的真实输入框 (负责统一处理键盘输入、复制粘贴与丝滑回退删除)
                        TextField("", text: $fullPinText)
                            .keyboardType(.numberPad)
                            .focused($isFieldFocused)
                            .opacity(0.01)
                            .frame(width: 1, height: 1)
                            .onChange(of: fullPinText) { _, newValue in
                                let filtered = String(newValue.filter { $0.isNumber }.prefix(6))
                                if filtered != newValue {
                                    fullPinText = filtered
                                }
                                errorMessage = nil

                                // 2. 输入完 6 位配对码后自动触发确认与校验
                                if filtered.count == 6 && !isVerifying && !isSuccess {
                                    verifyAndConfirm(pin: filtered)
                                }
                            }

                        // 上层渲染的 6 个精致数字方框
                        HStack(spacing: 10) {
                            ForEach(0..<6, id: \.self) { index in
                                let digit = getDigit(at: index)
                                let isActive = isFieldFocused && (fullPinText.count == index || (fullPinText.count == 6 && index == 5))

                                ZStack {
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(Color(.secondarySystemBackground))
                                        .frame(width: 46, height: 56)

                                    if !digit.isEmpty {
                                        Text(digit)
                                            .font(.system(size: 26, weight: .bold, design: .monospaced))
                                            .foregroundStyle(isSuccess ? Color.green : Color.primary)
                                            .transition(.scale.combined(with: .opacity))
                                    } else if isActive {
                                        // 闪烁光标指示器
                                        RoundedRectangle(cornerRadius: 1)
                                            .fill(Color.blue)
                                            .frame(width: 2, height: 22)
                                    }
                                }
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(
                                            isSuccess ? Color.green : (isActive ? Color.blue : (errorMessage != nil ? Color.red.opacity(0.6) : Color.clear)),
                                            lineWidth: isActive || isSuccess ? 2 : 1
                                        )
                                )
                            }
                        }
                        .offset(x: shakeOffset)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            isFieldFocused = true
                        }
                    }
                    .padding(.horizontal)

                    // 错误或校验提示信息
                    if isVerifying {
                        HStack(spacing: 8) {
                            ProgressView()
                                .scaleEffect(0.8)
                            Text("正在向电脑验证配对密钥...")
                                .font(.caption.bold())
                                .foregroundStyle(.blue)
                        }
                    } else if let error = errorMessage {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.circle.fill")
                            Text(error)
                        }
                        .font(.caption.bold())
                        .foregroundStyle(.red)
                        .transition(.opacity)
                    }

                    // 确认绑定按钮
                    Button {
                        if fullPinText.count == 6 && !isVerifying {
                            verifyAndConfirm(pin: fullPinText)
                        }
                    } label: {
                        HStack(spacing: 8) {
                            if isVerifying {
                                ProgressView()
                                    .tint(.white)
                            }
                            Text(isSuccess ? "已配对" : (isVerifying ? "正在校验..." : "确认配对并加密"))
                                .font(.headline)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(isSuccess ? Color.green : (fullPinText.count == 6 ? Color.blue : Color.blue.opacity(0.4)))
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    .disabled(fullPinText.count != 6 || isVerifying || isSuccess)
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
                }
                .padding(.bottom, 20)
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("设备配对")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") {
                        isPresented = false
                    }
                }
            }
            .onAppear {
                let currentPin = PasteLinkStore.shared.getLastEnteredPIN()
                if currentPin.count == 6 {
                    fullPinText = currentPin
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    isFieldFocused = true
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(24)
    }

    private func getDigit(at index: Int) -> String {
        guard index < fullPinText.count else { return "" }
        let charIndex = fullPinText.index(fullPinText.startIndex, offsetBy: index)
        return String(fullPinText[charIndex])
    }

    /// 1. 执行配对码校验握手
    private func verifyAndConfirm(pin: String) {
        guard !isVerifying else { return }
        isVerifying = true
        errorMessage = nil

        // 立即记录为最近输入的配对码，确保重启或意外退出也不会丢失
        PasteLinkStore.shared.savePairingPIN(pin)

        Task {
            let (success, message) = await BluetoothManager.shared.verifyPairingPIN(candidatePin: pin)

            await MainActor.run {
                self.isVerifying = false
                if success {
                    self.isSuccess = true
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    self.onPaired?(pin)

                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                        self.isPresented = false
                    }
                } else {
                    self.isSuccess = false
                    UINotificationFeedbackGenerator().notificationOccurred(.error)
                    self.errorMessage = message

                    // 错误抖动反馈，但保留用户已输入的配对码，绝不强制清空
                    withAnimation(.easeInOut(duration: 0.08).repeatCount(4, autoreverses: true)) {
                        self.shakeOffset = 8
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        self.shakeOffset = 0
                        self.isFieldFocused = true
                    }
                }
            }
        }
    }
}

#Preview {
    PairingSheet(isPresented: .constant(true))
}
