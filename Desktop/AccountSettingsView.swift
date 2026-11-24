import SwiftUI

struct AccountSettingsView: View {
    @ObservedObject var store: AssignmentStore
    @State private var accounts: [SchoolAccount] = Accounts.load().accounts
    @State private var active = Accounts.activeID
    @State private var newLabel = ""
    @State private var editing: SchoolAccount?
    @State private var editLabel = ""
    @State private var switching: SchoolAccount?
    @State private var deleting: SchoolAccount?
    @State private var notice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label("School Accounts", systemImage: "person.2").font(.headline)
            Text("Each account keeps its own login, assignments, grades, attachments and reports in a separate folder. Switching restarts the app.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(accounts) { account in
                HStack(spacing: 10) {
                    Image(systemName: account.id == active ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(account.id == active ? jade : Color.secondary)
                    Text(account.label)
                    if account.id == active {
                        Text("In use").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Rename") { editing = account; editLabel = account.label }
                    if account.id != active {
                        Button("Switch") { switching = account }
                    }
                    Button("Delete") { deleting = account }
                        .disabled(accounts.count <= 1 || account.id == active)
                }
                .font(.callout)
            }

            HStack(spacing: 8) {
                TextField("New account name", text: $newLabel)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                Button("Add Account") { add() }
                    .disabled(newLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if let notice {
                Text(notice).font(.caption).foregroundStyle(.orange)
            }
        }
        .sheet(item: $editing) { account in
            VStack(alignment: .leading, spacing: 14) {
                Text("Rename Account").font(.headline)
                TextField("Account name", text: $editLabel).textFieldStyle(.roundedBorder).frame(width: 260)
                HStack {
                    Spacer()
                    Button("Cancel") { editing = nil }
                    Button("Save") {
                        let label = editLabel.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !label.isEmpty { Accounts.rename(account.id, label: label); reload() }
                        editing = nil
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
        }
        .alert("Switch account?", isPresented: Binding(get: { switching != nil }, set: { if !$0 { switching = nil } })) {
            Button("Cancel", role: .cancel) { switching = nil }
            Button("Switch and Restart") {
                if let account = switching { Accounts.activate(account.id); Accounts.relaunch() }
                switching = nil
            }
        } message: {
            Text("The app restarts and loads only this account's data.")
        }
        .alert("Delete account?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Cancel", role: .cancel) { deleting = nil }
            Button("Delete", role: .destructive) {
                if let account = deleting {
                    do { try Accounts.remove(account.id) } catch { notice = error.localizedDescription }
                    reload()
                }
                deleting = nil
            }
        } message: {
            Text("Removes the local folder and saved login for this account. The school account itself is unchanged.")
        }
    }

    private func add() {
        let label = newLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { return }
        Accounts.create(label: label)
        newLabel = ""
        notice = "Added. Switch to it and sign in with that school account."
        reload()
    }

    private func reload() {
        accounts = Accounts.load().accounts
        active = Accounts.activeID
    }
}
