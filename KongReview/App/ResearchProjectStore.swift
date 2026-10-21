import Foundation
import KongReviewCore

// MARK: - 4.0：研究项目

/// 新建项目时顺带归入的笔记本或出处
struct ResearchProjectPendingLink: Equatable, Sendable {
    var kind: ResearchProjectLink.Kind
    var recordId: Int64
}

extension LibraryStore {
    /// 当前项目（沿用 3.15 本期焦点的存储，kind = project）
    var currentProjectID: Int64? {
        guard let focus = learningFocus, focus.kind == .project else { return nil }
        return focus.id
    }

    var currentProject: ResearchProject? {
        guard let id = currentProjectID else { return nil }
        return researchProjects.first { $0.id == id }
    }

    func refreshResearchProjects() {
        researchProjects = (try? db.researchProjects()) ?? []
        researchProjectRevision += 1
    }

    private func afterResearchProjectChange() {
        refreshResearchProjects()
        refreshLearningFocus()
        journeyRevision += 1
        revisionBump()
    }

    /// 打开新建项目面板；从笔记本或出处页进入时，保存后自动归入
    func newResearchProject(linking link: ResearchProjectPendingLink? = nil) {
        guard !fullBackupBusy else { return }
        researchProjectPendingLink = link
        researchProjectEditor = ResearchProject(title: "")
    }

    func editResearchProject(_ project: ResearchProject) {
        guard !fullBackupBusy else { return }
        researchProjectPendingLink = nil
        researchProjectEditor = project
    }

    /// 保存项目；新建的项目在没有当前项目时自动设为当前项目，并打开项目页
    @discardableResult
    func saveResearchProject(_ project: ResearchProject) -> ResearchProject? {
        guard !fullBackupBusy else { return nil }
        do {
            let isNew = project.id == nil
            let saved = try db.saveResearchProject(project)
            if let id = saved.id, let link = researchProjectPendingLink {
                try db.linkToResearchProject(id, kind: link.kind, recordId: link.recordId)
            }
            researchProjectPendingLink = nil
            if isNew, currentProjectID == nil, let id = saved.id {
                try db.setLearningFocus(LearningFocus(kind: .project, id: id, title: saved.title))
            }
            afterResearchProjectChange()
            if isNew, let id = saved.id { selection = .project(id) }
            return saved
        } catch {
            report(error)
            return nil
        }
    }

    func setResearchProjectStage(_ project: ResearchProject, _ stage: ResearchProject.Stage) {
        guard !fullBackupBusy, let id = project.id else { return }
        do { try db.setResearchProjectStage(id: id, stage: stage); afterResearchProjectChange() } catch { report(error) }
    }

    func setResearchProjectArchived(_ project: ResearchProject, _ archived: Bool) {
        guard !fullBackupBusy, let id = project.id else { return }
        do { try db.setResearchProjectArchived(id: id, archived: archived); afterResearchProjectChange() } catch { report(error) }
    }

    func deleteResearchProject(_ project: ResearchProject) {
        guard !fullBackupBusy, let id = project.id else { return }
        do {
            try db.deleteResearchProject(id: id)
            if selection == .project(id) { selection = .projects }
            afterResearchProjectChange()
        } catch { report(error) }
    }

    /// 设为当前项目：回顾抽样对项目材料中的摘录加权，记忆卡优先其卡片（与 3.15 本期焦点相同）
    func setCurrentProject(_ project: ResearchProject?) {
        guard let project else { setLearningFocus(nil); return }
        guard let id = project.id, !project.isArchived else { return }
        setLearningFocus(LearningFocus(kind: .project, id: id, title: project.title))
    }

    func linkToResearchProject(_ project: ResearchProject, kind: ResearchProjectLink.Kind, recordId: Int64) {
        guard !fullBackupBusy, let id = project.id else { return }
        do { try db.linkToResearchProject(id, kind: kind, recordId: recordId); afterResearchProjectChange() } catch { report(error) }
    }

    func unlinkFromResearchProject(_ project: ResearchProject, kind: ResearchProjectLink.Kind, recordId: Int64) {
        guard !fullBackupBusy, let id = project.id else { return }
        do { try db.unlinkFromResearchProject(id, kind: kind, recordId: recordId); afterResearchProjectChange() } catch { report(error) }
    }

    /// 某笔记本或出处所属的项目（工具栏“归入项目”菜单用）
    func researchProjects(containing kind: ResearchProjectLink.Kind, recordId: Int64) -> [ResearchProject] {
        _ = researchProjectRevision
        return (try? db.researchProjects(containing: kind, recordId: recordId)) ?? []
    }
}
