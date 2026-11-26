import PurrdrAgentFeatures

/// 以 alert 顯示的「會員」與「訂閱」提示裡,屬於錯誤的那幾種(#637):畫面出現時記進操作記錄。
/// 類別是提示型別名、錯誤碼是 case 名稱(`.failed` 的說明文字不進記錄);純告知與引導登入的提示不算錯誤。
extension MemberNotice {
    var displayedError: DisplayedError? {
        let code: String
        switch self {
        case .failed: code = "failed"
        case .subscriptionConflict: code = "subscriptionConflict"
        case .subscriptionInUse: code = "subscriptionInUse"
        case .methodAlreadyLinked: code = "methodAlreadyLinked"
        case .signedOut: code = "signedOut"
        case .signOutBackendUnreachable: code = "signOutBackendUnreachable"
        case .merged, .autoLinked, .deleted: return nil
        }
        return DisplayedError(message, category: "MemberNotice", code: code)
    }
}

extension SubscriptionNotice {
    var displayedError: DisplayedError? {
        let code: String
        switch self {
        case .failed: code = "failed"
        case .ownerNotConfirmed: code = "ownerNotConfirmed"
        case .inUseByAnotherMember: code = "inUseByAnotherMember"
        case .transferBlocked: code = "transferBlocked"
        case .alreadySubscribed: code = "alreadySubscribed"
        case .welcome, .restored, .nothingToRestore, .pending, .purchaseNotDelivered, .signInRequired, .transferred: return nil
        }
        return DisplayedError(message, category: "SubscriptionNotice", code: code)
    }
}
