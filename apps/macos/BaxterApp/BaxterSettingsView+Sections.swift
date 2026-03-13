import SwiftUI

extension BaxterSettingsView {
    var backupSection: some View {
        SettingsCard(title: "Backup", subtitle: "Choose folders to include in backups.") {
            VStack(alignment: .leading, spacing: 12) {
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

                if let error = model.validationMessage(for: .backupRoots) {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Exclude Paths")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Absolute paths, one per line.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $model.excludePathsText)
                        .scrollContentBackground(.hidden)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 82, maxHeight: 108)
                        .settingsEditorSurface()
                        .onChange(of: model.excludePathsText) { _, _ in
                            model.validateDraft()
                        }

                    if let error = model.validationMessage(for: .excludePaths) {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Exclude Globs")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Glob patterns, one per line.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $model.excludeGlobsText)
                        .scrollContentBackground(.hidden)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 82, maxHeight: 108)
                        .settingsEditorSurface()
                        .onChange(of: model.excludeGlobsText) { _, _ in
                            model.validateDraft()
                        }

                    if let error = model.validationMessage(for: .excludeGlobs) {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                SettingRow(label: "Backup Schedule", error: nil) {
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
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 92, alignment: .leading)
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
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 92, alignment: .leading)
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
                SettingRow(label: "Verify Schedule", error: nil) {
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
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 92, alignment: .leading)
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
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 92, alignment: .leading)
                            .onChange(of: model.verifyWeeklyTime) { _, _ in
                                model.validateDraft()
                            }
                    }
                }

                SettingRow(label: "Prefix", error: nil) {
                    TextField("/Users/you/Documents (optional)", text: $model.verifyPrefix)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .onChange(of: model.verifyPrefix) { _, _ in
                            model.validateDraft()
                        }
                }

                SettingRow(label: "Limit", error: model.validationMessage(for: .verifyLimit)) {
                    TextField("0", text: $model.verifyLimit)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 108, alignment: .leading)
                        .onChange(of: model.verifyLimit) { _, _ in
                            model.validateDraft()
                        }
                }

                SettingRow(label: "Sample", error: model.validationMessage(for: .verifySample)) {
                    TextField("0", text: $model.verifySample)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 108, alignment: .leading)
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
                    TextField("https://s3.amazonaws.com (optional)", text: $model.s3Endpoint)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: model.s3Endpoint) { _, _ in
                            model.validateDraft()
                        }
                }

                SettingRow(label: "Region", error: model.validationMessage(for: .s3Region)) {
                    TextField("us-west-2", text: $model.s3Region)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: model.s3Region) { _, _ in
                            model.validateDraft()
                        }
                }

                SettingRow(label: "Bucket", error: model.validationMessage(for: .s3Bucket)) {
                    TextField("my-backups", text: $model.s3Bucket)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: model.s3Bucket) { _, _ in
                            model.validateDraft()
                        }
                }

                SettingRow(label: "Prefix", error: model.validationMessage(for: .s3Prefix)) {
                    TextField("baxter/", text: $model.s3Prefix)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: model.s3Prefix) { _, _ in
                            model.validateDraft()
                        }
                }

                SettingRow(label: "AWS Profile", error: model.validationMessage(for: .s3AWSProfile)) {
                    TextField("baxter (optional)", text: $model.s3AWSProfile)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .onChange(of: model.s3AWSProfile) { _, _ in
                            model.validateDraft()
                        }
                }

                Text(model.s3ModeHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 136)
            }
        }
    }

    var encryptionSection: some View {
        SettingsCard(title: "Encryption", subtitle: "Keychain item used when BAXTER_PASSPHRASE is not set.") {
            VStack(alignment: .leading, spacing: 10) {
                SettingRow(label: "Service", error: model.validationMessage(for: .keychainService)) {
                    TextField("baxter", text: $model.keychainService)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: model.keychainService) { _, _ in
                            model.validateDraft()
                        }
                }

                SettingRow(label: "Account", error: model.validationMessage(for: .keychainAccount)) {
                    TextField("default", text: $model.keychainAccount)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: model.keychainAccount) { _, _ in
                            model.validateDraft()
                        }
                }
            }
        }
    }

    var notificationsSection: some View {
        SettingsCard(title: "Notifications", subtitle: "Failure alerts are always enabled; success alerts are optional.") {
            Toggle("Notify on successful backup/verify", isOn: $statusModel.notifyOnSuccess)
                .toggleStyle(.switch)
        }
    }
}
