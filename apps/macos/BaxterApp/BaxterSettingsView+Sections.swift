import SwiftUI

extension BaxterSettingsView {
    @ViewBuilder
    var generalSections: some View {
        backupRootsSection(footer: "Baxter backs up everything inside these folders.")

        Section {
            TextEditor(text: $model.excludePathsText)
                .font(.body.monospaced())
                .frame(height: 72)
                .onChange(of: model.excludePathsText) { _, _ in
                    model.validateDraft()
                }
            fieldError(.excludePaths)
        } header: {
            Text("Excluded Paths")
        } footer: {
            Text("Absolute paths, one per line.")
        }

        Section {
            TextEditor(text: $model.excludeGlobsText)
                .font(.body.monospaced())
                .frame(height: 72)
                .onChange(of: model.excludeGlobsText) { _, _ in
                    model.validateDraft()
                }
            fieldError(.excludeGlobs)
        } header: {
            Text("Excluded Patterns")
        } footer: {
            Text("Glob patterns, one per line.")
        }

        Section {
            LabeledContent("Config File") {
                Text(model.configURL.path)
                    .font(.callout.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
    }

    func backupRootsSection(footer: String) -> some View {
        Section {
            List(selection: $selectedBackupRoots) {
                ForEach(model.backupRoots, id: \.self) { root in
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(root)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if let warning = model.backupRootWarning(for: root) {
                                Text(warning)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                        }
                    } icon: {
                        Image(systemName: "folder")
                    }
                }
            }
            .frame(height: 120)
            .overlay {
                if model.backupRoots.isEmpty {
                    Text("No Folders")
                        .foregroundStyle(.secondary)
                }
            }
            .onDeleteCommand(perform: removeSelectedBackupRoots)

            HStack(spacing: 12) {
                Button {
                    model.chooseBackupRoots()
                } label: {
                    Image(systemName: "plus")
                }
                .help("Add folders to back up")
                .accessibilityLabel("Add Folder")

                Button(action: removeSelectedBackupRoots) {
                    Image(systemName: "minus")
                }
                .disabled(selectedBackupRoots.isEmpty)
                .help("Remove the selected folders")
                .accessibilityLabel("Remove Folder")

                Spacer()
            }
            .buttonStyle(.borderless)

            fieldError(.backupRoots)
        } header: {
            Text("Folders")
        } footer: {
            Text(footer)
        }
    }

    private func removeSelectedBackupRoots() {
        for root in selectedBackupRoots {
            model.removeBackupRoot(root)
        }
        selectedBackupRoots = []
    }

    @ViewBuilder
    var scheduleSections: some View {
        Section("Backup") {
            schedulePicker("Run Backups", selection: $model.schedule)
            if model.schedule == .weekly {
                weekdayPicker(selection: $model.weeklyDay)
                timePicker(\.weeklyTime)
                timeError(.weeklyTime, storedValue: model.weeklyTime)
            }
            if model.schedule == .daily {
                timePicker(\.dailyTime)
                timeError(.dailyTime, storedValue: model.dailyTime)
            }
        }

        Section("Verify") {
            schedulePicker("Run Verification", selection: $model.verifySchedule)
            if model.verifySchedule == .weekly {
                weekdayPicker(selection: $model.verifyWeeklyDay)
                timePicker(\.verifyWeeklyTime)
                timeError(.verifyWeeklyTime, storedValue: model.verifyWeeklyTime)
            }
            if model.verifySchedule == .daily {
                timePicker(\.verifyDailyTime)
                timeError(.verifyDailyTime, storedValue: model.verifyDailyTime)
            }
        }

        Section {
            TextField("Path Prefix", text: $model.verifyPrefix, prompt: Text("All backed-up paths"))
                .onChange(of: model.verifyPrefix) { _, _ in
                    model.validateDraft()
                }

            TextField("Limit", text: $model.verifyLimit, prompt: Text("0"))
                .onChange(of: model.verifyLimit) { _, _ in
                    model.validateDraft()
                }
            fieldError(.verifyLimit)

            TextField("Sample", text: $model.verifySample, prompt: Text("0"))
                .onChange(of: model.verifySample) { _, _ in
                    model.validateDraft()
                }
            fieldError(.verifySample)
        } header: {
            Text("Verify Scope")
        } footer: {
            Text("Limit and sample are file counts. Use 0 to check everything.")
        }
    }

    func schedulePicker(_ title: String, selection: Binding<BackupSchedule>) -> some View {
        Picker(title, selection: selection) {
            ForEach(BackupSchedule.allCases) { schedule in
                Text(schedule.rawValue.capitalized).tag(schedule)
            }
        }
        .onChange(of: selection.wrappedValue) { _, _ in
            model.validateDraft()
        }
    }

    private func weekdayPicker(selection: Binding<WeekdayOption>) -> some View {
        Picker("Day", selection: selection) {
            ForEach(WeekdayOption.allCases) { day in
                Text(day.rawValue.capitalized).tag(day)
            }
        }
        .onChange(of: selection.wrappedValue) { _, _ in
            model.validateDraft()
        }
    }

    @ViewBuilder
    private func timeError(_ field: SettingsField, storedValue: String) -> some View {
        if model.validationMessage(for: field) != nil {
            Text("The saved time “\(storedValue)” is not valid. Choose a time to replace it.")
                .font(.callout)
                .foregroundStyle(.red)
        }
    }

    private func timePicker(_ keyPath: ReferenceWritableKeyPath<BaxterSettingsModel, String>) -> some View {
        DatePicker("Time", selection: model.timeOfDayBinding(keyPath), displayedComponents: .hourAndMinute)
    }

    @ViewBuilder
    var storageSections: some View {
        Section {
            s3Fields
        } header: {
            Text("S3")
        } footer: {
            Text(model.s3ModeHint)
        }
    }

    @ViewBuilder
    var s3Fields: some View {
        TextField("Bucket", text: $model.s3Bucket, prompt: Text("my-backups"))
            .onChange(of: model.s3Bucket) { _, _ in
                model.validateDraft()
            }
        fieldError(.s3Bucket)

        TextField("Region", text: $model.s3Region, prompt: Text("us-west-2"))
            .onChange(of: model.s3Region) { _, _ in
                model.validateDraft()
            }
        fieldError(.s3Region)

        TextField("Endpoint", text: $model.s3Endpoint, prompt: Text("Optional"))
            .onChange(of: model.s3Endpoint) { _, _ in
                model.validateDraft()
            }
        fieldError(.s3Endpoint)

        TextField("Prefix", text: $model.s3Prefix, prompt: Text("baxter/"))
            .onChange(of: model.s3Prefix) { _, _ in
                model.validateDraft()
            }
        fieldError(.s3Prefix)

        TextField("AWS Profile", text: $model.s3AWSProfile, prompt: Text("Optional"))
            .onChange(of: model.s3AWSProfile) { _, _ in
                model.validateDraft()
            }
        fieldError(.s3AWSProfile)
    }

    @ViewBuilder
    var encryptionSections: some View {
        Section {
            TextField("Service", text: $model.keychainService, prompt: Text("baxter"))
                .onChange(of: model.keychainService) { _, _ in
                    model.validateDraft()
                }
            fieldError(.keychainService)

            TextField("Account", text: $model.keychainAccount, prompt: Text("default"))
                .onChange(of: model.keychainAccount) { _, _ in
                    model.validateDraft()
                }
            fieldError(.keychainAccount)
        } header: {
            Text("Keychain Item")
        } footer: {
            Text("Baxter reads the passphrase from this keychain item when BAXTER_PASSPHRASE is not set.")
        }
    }

    @ViewBuilder
    var notificationsSections: some View {
        Section {
            Toggle("Notify after successful runs", isOn: $statusModel.notifyOnSuccess)
        } footer: {
            Text("Baxter always notifies you when a backup or verify run fails.")
        }
    }
}
