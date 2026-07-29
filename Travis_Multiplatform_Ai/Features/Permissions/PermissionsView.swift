import SwiftUI

struct PermissionsView: View {
    @Bindable var appState: TRAVISAppState

    var body: some View {
        List {
            ForEach(appState.permissions) { permission in
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(permission.capability.title)
                            .font(.headline)

                        Spacer()

                        Toggle("", isOn: bindingForEnabled(permission))
                            .labelsHidden()
                    }

                    Picker("Policy", selection: bindingForPolicy(permission)) {
                        ForEach(PermissionPolicy.allCases) { policy in
                            Text(policy.title).tag(policy)
                        }
                    }
                    .pickerStyle(.menu)
                }
                .padding(.vertical, 6)
            }
        }
        .navigationTitle("Permissions")
    }

    private func bindingForEnabled(_ permission: TravisPermission) -> Binding<Bool> {
        Binding(
            get: {
                appState.permissions.first(where: { $0.id == permission.id })?.isEnabled ?? false
            },
            set: { _ in
                appState.togglePermissionEnabled(permission)
            }
        )
    }

    private func bindingForPolicy(_ permission: TravisPermission) -> Binding<PermissionPolicy> {
        Binding(
            get: {
                appState.permissions.first(where: { $0.id == permission.id })?.policy ?? .blocked
            },
            set: { newValue in
                appState.updatePermission(permission, to: newValue)
            }
        )
    }
}
