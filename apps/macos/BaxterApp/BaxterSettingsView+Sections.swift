import SwiftUI

extension BaxterSettingsView {
    var backupSection: some View {
        SettingsCard(title: "Backup", subtitle: "Choose folders to include in backups.") {
            VStack(alignment: .leading, spacing: 12) {
                SettingRow(label: "Folders", error: model.validationMessage(for: .backupRoots)) {
                    VStack(alignment: .leading, spacing: 8) {
                        backupRootsList

                        HStack(spacing: 8) {
                            Button("Add Folder...") {
                                model.chooseBackupRoots()
                            }
                            .buttonStyle(.bordered)

                            Button("Remove All") {
                                model.clearBackupRoots()
                            }
                            .buttonStyle(.bordered)
                            .disabled(model.backupRoots.isEmpty)
                        }
                    }
                }

                SettingRow(label: "Exclude Paths", error: model.validationMessage(for: .excludePaths)) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Absolute paths, one per line.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextEditor(text: $model.excludePathsText)
                            .scrollContentBackground(.hidden)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 82, maxHeight: 108)
                            .settingsEditorSurface()
                            .onChange(of: model.excludePathsText) { _, _ in
                                model.validateDraft()
                            }
                    }
                }

                SettingRow(label: "Exclude Globs", error: model.validationMessage(for: .excludeGlobs)) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Glob patterns, one per line.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextEditor(text: $model.excludeGlobsText)
                            .scrollContentBackground(.hidden)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 82, maxHeight: 108)
                            .settingsEditorSurface()
                            .onChange(of: model.excludeGlobsText) { _, _ in
                                model.validateDraft()
                            }
                    }
                }

                SettingRow(label: "Schedule", error: nil) {
                    Picker("Backup Schedule", selection: $model.schedule) {
                        ForEach(BackupSchedule.allCases) { schedule in
                            Text(schedule.rawValue.capitalized).tag(schedule)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 160, alignment: .leading)
                    .onChange(of: model.schedule) { _, _ in
                        model.validateDraft()
                    }
                }

                if model.schedule == .daily {
                    SettingRow(label: "Daily Time", error: model.validationMessage(for: .dailyTime)) {
                        TextField("HH:MM", text: $model.dailyTime)
                            .settingsField(width: 92, monospaced: true)
                            .onChange(of: model.dailyTime) { _, _ in
                                model.validateDraft()
                            }
                    }
                }

                if model.schedule == .weekly {
                    SettingRow(label: "Weekly Day", error: model.validationMessage(for: .weeklyDay)) {
                        Picker("Weekly Day", selection: $model.weeklyDay) {
                            ForEach(WeekdayOption.allCases) { day in
                                Text(day.rawValue.capitalized).tag(day)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 150, alignment: .leading)
                        .onChange(of: model.weeklyDay) { _, _ in
                            model.validateDraft()
                        }
                    }

                    SettingRow(label: "Weekly Time", error: model.validationMessage(for: .weeklyTime)) {
                        TextField("HH:MM", text: $model.weeklyTime)
                            .settingsField(width: 92, monospaced: true)
                            .onChange(of: model.weeklyTime) { _, _ in
                                model.validateDraft()
                            }
                    }
                }
            }
        }
    }

    @ViewBuilder
    var backupRootsList: some View {
        SettingsInsetGroup {
            if model.backupRoots.isEmpty {
                Text("No folders selected.")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            } else {
                ForEach(Array(model.backupRoots.enumerated()), id: \.element) { index, root in
                    if index > 0 {
                        Divider()
                            .padding(.leading, 12)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 10) {
                            Image(systemName: "folder")
                                .foregroundStyle(Color(nsColor: .systemBlue))
                            Text(root)
                                .font(.system(.body, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 0)
                            Button {
                                model.removeBackupRoot(root)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }

                        if let warning = model.backupRootWarning(for: root) {
                            Text(warning)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
            }
        }
    }

    var verifySection: some View {
        SettingsCard(title: "Verify", subtitle: "Schedule and scope integrity verification runs.") {
            VStack(alignment: .leading, spacing: 10) {
                SettingRow(label: "Schedule", error: nil) {
                    Picker("Verify Schedule", selection: $model.verifySchedule) {
                        ForEach(BackupSchedule.allCases) { schedule in
                            Text(schedule.rawValue.capitalized).tag(schedule)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 160, alignment: .leading)
                    .onChange(of: model.verifySchedule) { _, _ in
                        model.validateDraft()
                    }
                }

                if model.verifySchedule == .daily {
                    SettingRow(label: "Daily Time", error: model.validationMessage(for: .verifyDailyTime)) {
                        TextField("HH:MM", text: $model.verifyDailyTime)
                            .settingsField(width: 92, monospaced: true)
                            .onChange(of: model.verifyDailyTime) { _, _ in
                                model.validateDraft()
                            }
                    }
                }

                if model.verifySchedule == .weekly {
                    SettingRow(label: "Weekly Day", error: model.validationMessage(for: .verifyWeeklyDay)) {
                        Picker("Weekly Day", selection: $model.verifyWeeklyDay) {
                            ForEach(WeekdayOption.allCases) { day in
                                Text(day.rawValue.capitalized).tag(day)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 150, alignment: .leading)
                        .onChange(of: model.verifyWeeklyDay) { _, _ in
                            model.validateDraft()
                        }
                    }

                    SettingRow(label: "Weekly Time", error: model.validationMessage(for: .verifyWeeklyTime)) {
                        TextField("HH:MM", text: $model.verifyWeeklyTime)
                            .settingsField(width: 92, monospaced: true)
                            .onChange(of: model.verifyWeeklyTime) { _, _ in
                                model.validateDraft()
                            }
                    }
                }

                SettingRow(label: "Prefix", error: nil) {
                    TextField("/Users/you/Documents (optional)", text: $model.verifyPrefix)
                        .settingsField(width: 420, monospaced: true)
                        .onChange(of: model.verifyPrefix) { _, _ in
                            model.validateDraft()
                        }
                }

                SettingRow(label: "Limit", error: model.validationMessage(for: .verifyLimit)) {
                    TextField("0", text: $model.verifyLimit)
                        .settingsField(width: 108, monospaced: true)
                        .onChange(of: model.verifyLimit) { _, _ in
                            model.validateDraft()
                        }
                }

                SettingRow(label: "Sample", error: model.validationMessage(for: .verifySample)) {
                    TextField("0", text: $model.verifySample)
                        .settingsField(width: 108, monospaced: true)
                        .onChange(of: model.verifySample) { _, _ in
                            model.validateDraft()
                        }
                }
            }
        }
    }

    var s3Section: some View {
        SettingsCard(title: "S3", subtitle: "Leave bucket empty for local object storage.") {
            VStack(alignment: .leading, spacing: 10) {
                SettingRow(label: "Endpoint", error: model.validationMessage(for: .s3Endpoint)) {
                    TextField("Optional, for example https://s3.amazonaws.com", text: $model.s3Endpoint)
                        .settingsField(width: 420)
                        .onChange(of: model.s3Endpoint) { _, _ in
                            model.validateDraft()
                        }
                }

                SettingRow(label: "Region", error: model.validationMessage(for: .s3Region)) {
                    TextField("Example: us-west-2", text: $model.s3Region)
                        .settingsField(width: 180)
                        .onChange(of: model.s3Region) { _, _ in
                            model.validateDraft()
                        }
                }

                SettingRow(label: "Bucket", error: model.validationMessage(for: .s3Bucket)) {
                    TextField("Example: my-backups", text: $model.s3Bucket)
                        .settingsField(width: 240)
                        .onChange(of: model.s3Bucket) { _, _ in
                            model.validateDraft()
                        }
                }

                SettingRow(label: "Prefix", error: model.validationMessage(for: .s3Prefix)) {
                    TextField("baxter/", text: $model.s3Prefix)
                        .settingsField(width: 180)
                        .onChange(of: model.s3Prefix) { _, _ in
                            model.validateDraft()
                        }
                }

                SettingRow(label: "AWS Profile", error: model.validationMessage(for: .s3AWSProfile)) {
                    TextField("Optional, for example baxter", text: $model.s3AWSProfile)
                        .settingsField(width: 220, monospaced: true)
                        .onChange(of: model.s3AWSProfile) { _, _ in
                            model.validateDraft()
                        }
                }

                SettingsAlignedContent {
                    Text(model.s3ModeHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    var encryptionSection: some View {
        SettingsCard(title: "Encryption", subtitle: "Keychain item used when BAXTER_PASSPHRASE is not set.") {
            VStack(alignment: .leading, spacing: 10) {
                SettingRow(label: "Service", error: model.validationMessage(for: .keychainService)) {
                    TextField("baxter", text: $model.keychainService)
                        .settingsField(width: 180)
                        .onChange(of: model.keychainService) { _, _ in
                            model.validateDraft()
                        }
                }

                SettingRow(label: "Account", error: model.validationMessage(for: .keychainAccount)) {
                    TextField("default", text: $model.keychainAccount)
                        .settingsField(width: 180)
                        .onChange(of: model.keychainAccount) { _, _ in
                            model.validateDraft()
                        }
                }
            }
        }
    }

    var notificationsSection: some View {
        SettingsCard(title: "Notifications", subtitle: "Failure alerts are always enabled; success alerts are optional.") {
            SettingRow(label: "Success Alerts", error: nil) {
                Toggle("Notify after successful backup and verify runs", isOn: $statusModel.notifyOnSuccess)
                    .toggleStyle(.switch)
            }
        }
    }
}
