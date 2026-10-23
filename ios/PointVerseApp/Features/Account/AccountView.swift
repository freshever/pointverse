import AuthenticationServices
import GoogleSignInSwift
import PointVerseKit
import SwiftUI

struct AccountView: View {
    var library: CloudLocalLibrary? = nil
    @EnvironmentObject private var account: AccountSessionStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var confirmingLogout = false
    @State private var email = ""
    @State private var password = ""
    @FocusState private var focusedField: LoginField?
    private enum LoginField { case email, password }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 14) {
                    Image(systemName: account.user == nil ? "person.crop.circle.badge.plus" : "person.crop.circle.fill")
                        .font(.system(size: 48, weight: .light)).foregroundStyle(.indigo)
                        .frame(width: 92, height: 92)
                        .background(.indigo.opacity(0.09), in: RoundedRectangle(cornerRadius: 28))
                    AppText(account.user == nil ? "你的点界账户" : "已登录点界")
                        .font(.title2.bold())
                    AppText(account.user == nil ? "选择一种方式，连接你的账户。" : "在这里管理你的登录状态。")
                        .font(.subheadline).foregroundStyle(.secondary)
                }.padding(.top, 24)

                if let user = account.user {
                    VStack(alignment: .leading, spacing: 14) {
                        if !user.displayName.isEmpty { Text(verbatim: user.displayName).font(.headline) }
                        ForEach(user.identities, id: \.provider) { identity in
                            HStack {
                                Label(identity.provider == "apple" ? "Apple" : (identity.provider == "email" ? AppLocalization.string("邮箱账户", language: language) : "Google"), systemImage: identity.provider == "apple" ? "apple.logo" : (identity.provider == "email" ? "envelope" : "person.crop.circle"))
                                Spacer()
                                if let email = identity.email { Text(verbatim: email).font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled) }
                            }
                        }
                        if user.identities.contains(where: { $0.provider == "email" && !$0.emailVerified }) {
                            AppText("邮箱未验证 · 不影响当前登录").font(.caption).foregroundStyle(.secondary)
                        }
                        AppText(account.isVerified ? "已连接账户服务" : "离线 · 等待验证账户")
                            .font(.caption).foregroundStyle(.secondary)
                        if let library {
                            Divider()
                            NavigationLink { CloudSyncView(library: library).id(account.serverAddress + user.id) } label: {
                                Label("云端同步", systemImage: "icloud.and.arrow.up")
                            }
                            Text("选择一条或多条想法上传，并在网页查看。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Divider()
                        Button(role: .destructive) { confirmingLogout = true } label: {
                            AppText("退出登录").frame(maxWidth: .infinity, minHeight: 32)
                        }.disabled(account.isBusy || account.isSyncing)
                    }.padding(20).background(.background, in: RoundedRectangle(cornerRadius: 22))
                } else {
                    VStack(alignment: .leading, spacing: 16) {
                        AppText("邮箱登录").font(.headline)
                        VStack(alignment: .leading, spacing: 8) {
                            AppText("邮箱地址").font(.caption).foregroundStyle(.secondary)
                            TextField("you@example.com", text: $email)
                                .keyboardType(.emailAddress).textContentType(.username)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                                .focused($focusedField, equals: .email).submitLabel(.next)
                                .onSubmit { focusedField = .password }
                                .padding(12).background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
                                .accessibilityIdentifier("account.email")
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            AppText("密码").font(.caption).foregroundStyle(.secondary)
                            SecureField(AppLocalization.string("输入你的密码", language: language), text: $password)
                                .textContentType(.password).focused($focusedField, equals: .password)
                                .submitLabel(.go).onSubmit { submitEmail() }
                                .padding(12).background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
                                .accessibilityIdentifier("account.password")
                        }
                        Button(action: submitEmail) {
                            AppText("登录").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 9)
                        }.buttonStyle(.borderedProminent).tint(.indigo)
                            .disabled(account.isBusy)
                            .accessibilityIdentifier("account.emailLogin")
                        Link(destination: account.registrationURL) { AppText("还没有账户？前往网页注册").font(.footnote) }
                            .frame(maxWidth: .infinity).disabled(account.isBusy)
                        AppText("使用在网页注册的邮箱和密码登录。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }.disabled(account.isBusy).padding(20).background(.background, in: RoundedRectangle(cornerRadius: 22))
                    if account.appleAvailable || account.googleAvailable {
                        VStack(spacing: 14) {
                            AppText("其他登录方式").font(.caption).foregroundStyle(.secondary)
                            if account.appleAvailable {
                                AppleAccountButton(enabled: !account.isBusy, dark: colorScheme == .dark) {
                                    Task { await account.loginApple() }
                                }.id(colorScheme).frame(height: 50).accessibilityLabel(Text("通过 Apple 登录"))
                            }
                            if account.googleAvailable {
                                GoogleSignInButton { Task { await account.loginGoogle() } }
                                    .frame(height: 50).disabled(account.isBusy)
                            }
                        }
                    }
                }

                if account.isBusy {
                    HStack(spacing: 10) { ProgressView(); AppText("正在连接账户…").font(.footnote).foregroundStyle(.secondary) }
                        .accessibilityElement(children: .combine)
                }
                if let error = account.errorMessage {
                    VStack(spacing: 10) {
                        AppText(error).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button { Task { await account.refresh() } } label: { AppText("重试") }.disabled(account.isBusy)
                    }
                }
                Label { AppText("登录不会自动上传想法、录音或图片。本地记录始终可用。") } icon: { Image(systemName: "lock.shield") }
                    .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: 440).padding(.horizontal, 24).padding(.bottom, 28).frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(AppLocalization.string("账户", language: language))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await account.refresh()
        }
        .onChange(of: account.user?.id) { _, _ in password = ""; focusedField = nil }
        .onDisappear { password = "" }
        .scrollDismissesKeyboard(.interactively)
        .confirmationDialog("退出当前账户？", isPresented: $confirmingLogout, titleVisibility: .visible) {
            Button("退出登录", role: .destructive) { Task { await account.logout() } }
            Button("取消", role: .cancel) { }
        } message: { Text("本机保存的想法、录音和图片会保留。") }
    }
    private func submitEmail() {
        guard !account.isBusy else { return }
        focusedField = nil
        Task { await account.loginEmail(email: email, password: password) }
    }
    @Environment(\.appLanguage) private var language
}

private struct AppleAccountButton: UIViewRepresentable {
    let enabled: Bool
    let dark: Bool
    let action: @MainActor () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(action: action) }
    func makeUIView(context: Context) -> ASAuthorizationAppleIDButton {
        let button = ASAuthorizationAppleIDButton(type: .signIn, style: dark ? .white : .black)
        button.cornerRadius = 8
        button.addTarget(context.coordinator, action: #selector(Coordinator.tapped), for: .touchUpInside)
        return button
    }
    func updateUIView(_ button: ASAuthorizationAppleIDButton, context: Context) {
        button.isEnabled = enabled
        button.alpha = enabled ? 1 : 0.4
    }
    @MainActor final class Coordinator: NSObject {
        let action: @MainActor () -> Void
        init(action: @escaping @MainActor () -> Void) { self.action = action }
        @objc func tapped() { action() }
    }
}
