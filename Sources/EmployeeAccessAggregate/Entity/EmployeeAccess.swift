import DDDKit
import Foundation
import IAMContextShared
package class EmployeeAccess: EmployeeAccessAggregateProtocol {
    package let id: String
    package var metadata: AggregateRootMetadata = .init()

    // NOTE: removed duplicate `package var id: String?` (scaffold/adapter emitted bundle-state `id` on top of
    // DDDKit's required `package let id: String` above → invalid redeclaration). Proper long-term fix: exclude
    // `id` from state mapping in swift-adapter.yaml so a future `genesis new` won't reintroduce it.
    package var userId: String?
    package var permissions: Set<String>?
    package var roles: Set<String>?
    package var department: String?
    package var jobTitle: String?
    package var status: EmployeeStatus?

    package static var category: String {
        // NOTE: prefix 必須是 "IAM"（IAMContext → IAM），與 projection 的 $ce-IAMEmployeeAccess 及 presenter
        // categoryRule .fromClass(withPrefix: "IAM_") 對齊。原 codegen 產 "IAMC"（誤取 IAMContext 大寫字母）
        // → 寫入落在 $ce-IAMCEmployeeAccess、projection 訂 $ce-IAMEmployeeAccess → 事件流不到 projector、read model 永遠空。
        "IAM\(Self.self)"
    }

    // ── COPIED SNAPSHOT — 驗證用，非長期方案（human-authorized 2026-06-09）──
    // 從 OpportunityContext 的權威清單手動 copy 一份（154 條），用來快速驗證 enroll → GetPermissions →
    // OC PermissionMiddleware 的跨 context 執法 loop 是否打通。這是「快速驗證」的暫時手段，已知缺點 = drift
    // （OC 改了不會自動同步）。正式同步機制（OC 發布 catalog / IAM ingest）後續另議，屆時移除本區塊。
    //   來源：OpportunityContext/Sources/OCServer/OpportunityContext.permissions.yaml（SSOT；與 IAMPermissionCatalog 內複製品同步）
    //   版本：sha256 f7dd5e7018d66204db5758d73415969d9b5b60366fa14bfe048217c9909a92f0（2026-06-15 同步）
    //   組成：AuditQuoting 47 + QuotingCaseGrouping 29 + Quotation 14 + CompanyRegistrationQuoting 22
    //         + Workflow 9 + Query 31 + File 2 = 154
    //   2026-06-15 新增：QuotingCaseGrouping.ChangeCollaboratorRole（OC 的 changeCollaboratorRole）
    package static let allPermissions: Set<String> = [
        // AuditQuoting (47)
        "OpportunityContext.AuditQuoting.AddAccounting",
        "OpportunityContext.AuditQuoting.AddAccountingReform",
        "OpportunityContext.AuditQuoting.AddAssistanceAnnualSupplementaryPremiumDeductionDetailsReporting",
        "OpportunityContext.AuditQuoting.AddAssistanceCtp",
        "OpportunityContext.AuditQuoting.AddCashierOperation",
        "OpportunityContext.AuditQuoting.AddCustomizedReporting",
        "OpportunityContext.AuditQuoting.AddFinancialComplianceAudit",
        "OpportunityContext.AuditQuoting.AddPayrollSupportOperation",
        "OpportunityContext.AuditQuoting.AddTaxComplianceAudit",
        "OpportunityContext.AuditQuoting.AddTaxComplianceAuditAndUndistributedEarningsAudit",
        "OpportunityContext.AuditQuoting.ConfirmNoPredecessorAuditor",
        "OpportunityContext.AuditQuoting.CustomizeServiceItem",
        "OpportunityContext.AuditQuoting.DeleteCustomizedReporting",
        "OpportunityContext.AuditQuoting.EditAccountBalanceDetailReportNeed",
        "OpportunityContext.AuditQuoting.EditAccountingReformElectronicFileProvision",
        "OpportunityContext.AuditQuoting.EditAccountingType",
        "OpportunityContext.AuditQuoting.EditBalanceSheetNeed",
        "OpportunityContext.AuditQuoting.EditBranchCount",
        "OpportunityContext.AuditQuoting.EditBusinessTaxFilingMethod",
        "OpportunityContext.AuditQuoting.EditCommonBankMonthlyRecordCount",
        "OpportunityContext.AuditQuoting.EditCustomizedReporting",
        "OpportunityContext.AuditQuoting.EditDomesticTransferCount",
        "OpportunityContext.AuditQuoting.EditEstimatedEvidenceCount",
        "OpportunityContext.AuditQuoting.EditEstimatedHeadcountOfWithholding",
        "OpportunityContext.AuditQuoting.EditEstimatedRevenue",
        "OpportunityContext.AuditQuoting.EditIncomeStatementNeed",
        "OpportunityContext.AuditQuoting.EditIndustrialType",
        "OpportunityContext.AuditQuoting.EditInternationalTransferCount",
        "OpportunityContext.AuditQuoting.EditLastYearRevenue",
        "OpportunityContext.AuditQuoting.EditPaidInCapital",
        "OpportunityContext.AuditQuoting.EditPayrollHeadcount",
        "OpportunityContext.AuditQuoting.EditPayrollTransferCount",
        "OpportunityContext.AuditQuoting.EditProfitseekingEnterpriseIncomeTaxFilingMethod",
        "OpportunityContext.AuditQuoting.EditRegisteredCapital",
        "OpportunityContext.AuditQuoting.EditSalesEinvoiceUsage",
        "OpportunityContext.AuditQuoting.EditServiceItemEndDate",
        "OpportunityContext.AuditQuoting.EditServiceItemSelection",
        "OpportunityContext.AuditQuoting.EditServiceItemStartDate",
        "OpportunityContext.AuditQuoting.EditTotalAssets",
        "OpportunityContext.AuditQuoting.RecordPastCostAnalysisRequirement",
        "OpportunityContext.AuditQuoting.RecordPredecessorAuditorInfo",
        "OpportunityContext.AuditQuoting.RemoveQuotingProof",
        "OpportunityContext.AuditQuoting.RemoveServiceItems",
        "OpportunityContext.AuditQuoting.SelectAccountingWorkItems",
        "OpportunityContext.AuditQuoting.SelectCashierOperationWorkItems",
        "OpportunityContext.AuditQuoting.SelectPayrollSupportOperationWorkItems",
        "OpportunityContext.AuditQuoting.UploadQuotingProof",
        // QuotingCaseGrouping (29)
        "OpportunityContext.QuotingCaseGrouping.AddCollaborators",
        "OpportunityContext.QuotingCaseGrouping.AddContact",
        "OpportunityContext.QuotingCaseGrouping.AddQuotingBundle",
        "OpportunityContext.QuotingCaseGrouping.BackfillQuotation",
        "OpportunityContext.QuotingCaseGrouping.ChangeCollaboratorRole",
        "OpportunityContext.QuotingCaseGrouping.EditClientSource",
        "OpportunityContext.QuotingCaseGrouping.EditContactCommunicationMethods",
        "OpportunityContext.QuotingCaseGrouping.EditContactDisplayName",
        "OpportunityContext.QuotingCaseGrouping.EditContactGender",
        "OpportunityContext.QuotingCaseGrouping.EditContactRelationship",
        "OpportunityContext.QuotingCaseGrouping.EditQuotingCaseBusinessId",
        "OpportunityContext.QuotingCaseGrouping.EditQuotingCaseCompanyName",
        "OpportunityContext.QuotingCaseGrouping.EditQuotingCaseEstablishmentApprovalDate",
        "OpportunityContext.QuotingCaseGrouping.EditQuotingCaseName",
        "OpportunityContext.QuotingCaseGrouping.EditQuotingCaseOrganizationType",
        "OpportunityContext.QuotingCaseGrouping.EditQuotingFirm",
        "OpportunityContext.QuotingCaseGrouping.OpenQuotingCaseGrouping",
        "OpportunityContext.QuotingCaseGrouping.PriceServiceItems",
        "OpportunityContext.QuotingCaseGrouping.RemoveBackfilledQuotation",
        "OpportunityContext.QuotingCaseGrouping.RemoveCollaborator",
        "OpportunityContext.QuotingCaseGrouping.RemoveContact",
        "OpportunityContext.QuotingCaseGrouping.RemoveQuotingBundle",
        "OpportunityContext.QuotingCaseGrouping.RemoveQuotingCase",
        "OpportunityContext.QuotingCaseGrouping.RemoveReplyForm",
        "OpportunityContext.QuotingCaseGrouping.RenameQuotingBundle",
        "OpportunityContext.QuotingCaseGrouping.ReorderQuotingBundles",
        "OpportunityContext.QuotingCaseGrouping.ReorderQuotingCases",
        "OpportunityContext.QuotingCaseGrouping.SetPrimaryQuotingCase",
        "OpportunityContext.QuotingCaseGrouping.UploadReplyForm",
        // Quotation (14)
        "OpportunityContext.Quotation.AddContractNoteByUser",
        "OpportunityContext.Quotation.EditContractNote",
        "OpportunityContext.Quotation.EditFontSize",
        "OpportunityContext.Quotation.EditLetterContent",
        "OpportunityContext.Quotation.EditLetterFrom",
        "OpportunityContext.Quotation.EditLetterTitle",
        "OpportunityContext.Quotation.EditLetterTo",
        "OpportunityContext.Quotation.EditPaymentItemSupplementaryNoteContent",
        "OpportunityContext.Quotation.RemoveContractNoteByUser",
        "OpportunityContext.Quotation.RenamePaymentItem",
        "OpportunityContext.Quotation.ReorderContractNotes",
        "OpportunityContext.Quotation.ReorderPaymentItems",
        "OpportunityContext.Quotation.ResetPaymentItemSupplementaryNoteContent",
        "OpportunityContext.Quotation.SetPaymentItemSupplementaryNoteVisibility",
        // CompanyRegistrationQuoting (22)
        "OpportunityContext.CompanyRegistrationQuoting.AddAssistanceChairmanConvenienceSeal",
        "OpportunityContext.CompanyRegistrationQuoting.AddAssistanceChairmanSeal",
        "OpportunityContext.CompanyRegistrationQuoting.AddAssistanceCompanyConvenienceSeal",
        "OpportunityContext.CompanyRegistrationQuoting.AddAssistanceCompanySeal",
        "OpportunityContext.CompanyRegistrationQuoting.AddAssistanceInvoiceSeal",
        "OpportunityContext.CompanyRegistrationQuoting.AddAssistanceLaborAndHealthInsuranceInsuredUnitSetting",
        "OpportunityContext.CompanyRegistrationQuoting.AddAssistanceWithCompanyCertificationApplication",
        "OpportunityContext.CompanyRegistrationQuoting.AddCompanyRegistration",
        "OpportunityContext.CompanyRegistrationQuoting.AddOwnerOccupiedResidencePartForBusinessApplication",
        "OpportunityContext.CompanyRegistrationQuoting.ConfigureEconomicMinistryRegistrationCharged",
        "OpportunityContext.CompanyRegistrationQuoting.ConfigureEconomicMinistryRegistrationNoCharge",
        "OpportunityContext.CompanyRegistrationQuoting.EditChairmanConvenienceSealCount",
        "OpportunityContext.CompanyRegistrationQuoting.EditChairmanSealCount",
        "OpportunityContext.CompanyRegistrationQuoting.EditCompanyConvenienceSealCount",
        "OpportunityContext.CompanyRegistrationQuoting.EditCompanySealCount",
        "OpportunityContext.CompanyRegistrationQuoting.EditInvoiceSealCount",
        "OpportunityContext.CompanyRegistrationQuoting.EditIsFranchise",
        "OpportunityContext.CompanyRegistrationQuoting.EditServiceItemSelection",
        "OpportunityContext.CompanyRegistrationQuoting.EditServiceItemStartDate",
        "OpportunityContext.CompanyRegistrationQuoting.EditShareholderCount",
        "OpportunityContext.CompanyRegistrationQuoting.RemoveServiceItems",
        "OpportunityContext.CompanyRegistrationQuoting.SelectCompanyRegistrationWorkItems",
        // Workflow (9)
        "OpportunityContext.Workflow.AddQuotingCase",
        "OpportunityContext.Workflow.ArchiveQuotingCaseGrouping",
        "OpportunityContext.Workflow.CancelQuotingCaseGroupingDealClose",
        "OpportunityContext.Workflow.CancelQuotingCaseGroupingHandOver",
        "OpportunityContext.Workflow.CloseQuotingCasesDeal",
        "OpportunityContext.Workflow.CreateQuotingCaseGrouping",
        "OpportunityContext.Workflow.DeliverQuotingCase",
        "OpportunityContext.Workflow.HandOverQuotingCases",
        "OpportunityContext.Workflow.UnarchiveQuotingCaseGrouping",
        // Query (31)
        "OpportunityContext.Query.GetAccountingSetup",
        "OpportunityContext.Query.GetAgreementTerms",
        "OpportunityContext.Query.GetBackfilledQuotations",
        "OpportunityContext.Query.GetBusinessClientAssistance",
        "OpportunityContext.Query.GetClientSource",
        "OpportunityContext.Query.GetContacts",
        "OpportunityContext.Query.GetContractHeader",
        "OpportunityContext.Query.GetContractNotes",
        "OpportunityContext.Query.GetCustomerInfo",
        "OpportunityContext.Query.GetEvidenceInfo",
        "OpportunityContext.Query.GetLetter",
        "OpportunityContext.Query.GetOperationInfo",
        "OpportunityContext.Query.GetPaymentSummary",
        "OpportunityContext.Query.GetPredecessorServiceInfo",
        "OpportunityContext.Query.GetPurpose",
        "OpportunityContext.Query.GetQuotationPdfDownload",
        "OpportunityContext.Query.GetQuotationPdfPreview",
        "OpportunityContext.Query.GetQuotingBundles",
        "OpportunityContext.Query.GetQuotingCaseGroupingAggregateRootIds",
        "OpportunityContext.Query.GetQuotingCaseGroupingSummaries",
        "OpportunityContext.Query.GetQuotingCaseGroupingViewMode",
        "OpportunityContext.Query.GetQuotingCaseViewMode",
        "OpportunityContext.Query.GetQuotingCases",
        "OpportunityContext.Query.GetQuotingFirm",
        "OpportunityContext.Query.GetQuotingProofs",
        "OpportunityContext.Query.GetReplyForms",
        "OpportunityContext.Query.GetRightsAndObligations",
        "OpportunityContext.Query.GetServiceItemDetail",
        "OpportunityContext.Query.GetServiceItemsByQuotingBundleId",
        "OpportunityContext.Query.GetServiceScope",
        "OpportunityContext.Query.GetTemplateVariables",
        // File (2)
        "OpportunityContext.File.DownloadFile",
        "OpportunityContext.File.UploadEmbeddedImage",
    ]

    package init(id: String, userId: String, department: String, jobTitle: String, permissions: Set<String>, roles: Set<String>, status: EmployeeStatus) throws {
        self.id = id
        self.userId = userId
        self.department = department
        self.jobTitle = jobTitle
        self.permissions = permissions
        self.roles = roles
        self.status = status
        // GENESIS-STUB: validate input via ensureInvariant() before emitting createdEvent
        let event = UserAccessProfileCreated(
            employeeAccessId: id,
            userId: userId,
            department: department,
            jobTitle: jobTitle,
            permissions: permissions,
            roles: roles,
            status: status,
            occurred: .now
        )
        try self.apply(event: event)
    }
    // Create entry point used by the create use-case (/usecase Create pattern). The use-case Input does
    // NOT carry non-input createdEvent payload field(s) [permissions, roles, status], so deriving them is domain logic.
    package convenience init(id: String, userId: String, department: String, jobTitle: String) throws {
        // domain-fill placeholder (human-authorized 2026-06-03)：權限細項未規劃 → 新人先給「全部權限」、roles 空集合、status .Active。
        // TODO: 待 permission 方案定案後，依 (department, jobTitle) 推導真正的 permissions / roles。
        try self.init(
            id: id,
            userId: userId,
            department: department,
            jobTitle: jobTitle,
            permissions: Self.allPermissions,
            roles: [],
            status: .Active
        )
    }
    package required convenience init?(first createdEvent: UserAccessProfileCreated, other events: [any DomainEvent]) throws {
        try self.init(
            id: createdEvent.employeeAccessId,
            userId: createdEvent.userId,
            department: createdEvent.department,
            jobTitle: createdEvent.jobTitle,
            permissions: createdEvent.permissions,
            roles: createdEvent.roles,
            status: createdEvent.status
        )
        try self.apply(events: events)
        try self.clearAllDomainEvents()
    }

    package func ensureInvariant() throws {
        // domain-fill: (a) userIdNotExist + (c) employeeNotActive 由人口述轉錄；(b) permissionNotMatch held。
        // Bundle-declared invariants:
        //   - 確認 User ID 存在 (userIdNotExist): userId !== nil; userId !== null
        //   - 確認使用者身上的權限符合部門、職稱 (permissionNotMatch): userPermissions ⊇ baseline(department, jobTitle)
        //   - 員工必須在職 (employeeNotActive): status == activate

        // (a) 確認 User ID 存在 — userId 必須存在且非空字串（nil 或 "" 都擋）
        guard let userId, !userId.isEmpty else {
            throw ContextError<EmployeeAccessError>.userIdNotExist(function: #function, message: "userId must be present and non-empty")
        }

        // (c) 員工必須在職 — status 必須為 .Active
        guard status == .Active else {
            throw ContextError<EmployeeAccessError>.employeeNotActive(function: #function, message: "employee status must be Active")
        }

        // (b) 確認權限符合部門、職稱 — userPermissions ⊇ baseline(department, jobTitle)
        //     placeholder (human-authorized 2026-06-03)：baseline 細項未規劃 → 暫不強制（required = []）→ 一律通過。
        //     TODO: 權限方案定案後改為真正 baseline（例如 static [String: Set<String>] 對照表）。
        let required: Set<String> = []
        guard (permissions ?? []).isSuperset(of: required) else {
            throw ContextError<EmployeeAccessError>.permissionNotMatch(function: #function, message: "permissions do not satisfy baseline")
        }
    }
}
