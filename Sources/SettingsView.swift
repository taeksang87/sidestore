import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(RailAPI.keyStorage) private var apiKey = ""
    @State private var testing = false
    @State private var testResult: String?
    @State private var testFailed = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("일반 인증키 (Decoding)", text: $apiKey, axis: .vertical)
                        .font(.footnote.monospaced())
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .lineLimit(2...4)
                    Button {
                        test()
                    } label: {
                        HStack {
                            Text("연결 테스트")
                            Spacer()
                            if testing { ProgressView() }
                        }
                    }
                    .disabled(apiKey.isEmpty || testing)
                    if let testResult {
                        Text(testResult)
                            .font(.caption)
                            .foregroundColor(testFailed ? .red : .green)
                    }
                } header: {
                    Text("공공데이터포털 인증키")
                } footer: {
                    Text("인증키는 이 아이폰에만 저장돼요.")
                }

                Section("인증키 발급 방법") {
                    Text("1. 공공데이터포털(data.go.kr)에 로그인")
                    Text("2. 아래 두 API를 검색해서 각각 ‘활용신청’ (자동 승인)\n   • 국토교통부_(TAGO)_열차정보\n   • 국토교통부_(TAGO)_지하철정보")
                    Text("3. 마이페이지 → 개인 API 인증키에서 ‘일반 인증키(Decoding)’를 복사해 위에 붙여넣기")
                    Text("발급 직후에는 키가 활성화되기까지 1~2시간 걸릴 수 있어요.")
                        .foregroundColor(.secondary)
                    Link("공공데이터포털 열기", destination: URL(string: "https://www.data.go.kr")!)
                }
                .font(.subheadline)

                Section("자동 업데이트") {
                    Text("‘철도 API 자동 연동’을 켠 노선은 앱을 열 때 직통열차(KTX·ITX)는 하루 한 번, 광역전철 시간표는 7일에 한 번 새로 받아와요. 노선 화면에서 바로 업데이트할 수도 있어요.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("설정")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("완료") { dismiss() }
                }
            }
        }
    }

    private func test() {
        testing = true
        testResult = nil
        Task {
            do {
                let api = try RailAPI(serviceKey: apiKey)
                testResult = try await api.testConnection()
                testFailed = false
            } catch {
                testResult = error.localizedDescription
                testFailed = true
            }
            testing = false
        }
    }
}
