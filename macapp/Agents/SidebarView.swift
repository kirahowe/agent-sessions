import SwiftUI

struct SidebarView: View {
    @ObservedObject var store: AppStore

    var body: some View {
        List(selection: $store.selection) {
            ForEach(store.projects) { project in
                Section {
                    ForEach(store.sessions.filter { $0.projectPath == project.path }) { session in
                        HStack {
                            Image(systemName: "terminal")
                            Text(session.name)
                        }
                        .tag(session.id)
                        .contextMenu {
                            Button("Rename…") {
                                if let name = Dialogs.promptRename(currentName: session.name) {
                                    store.renameSession(session.id, to: name)
                                }
                            }
                            Button("Close Session") {
                                store.closeSession(session.id)
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text(project.name)
                        Spacer()
                        Button {
                            store.newSession(in: project)
                        } label: {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(.borderless)
                    }
                    .contextMenu {
                        Button("Remove Project…") {
                            if Dialogs.confirmRemove(project) {
                                store.removeProject(project)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            Button {
                if let path = Dialogs.chooseProjectDirectory() {
                    store.addProject(path: path)
                }
            } label: {
                Text("Add Project…")
                    .frame(maxWidth: .infinity)
            }
            .padding(8)
        }
    }
}
