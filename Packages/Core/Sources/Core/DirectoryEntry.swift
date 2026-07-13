public struct DirectoryEntry: Sendable, Equatable, Codable {
    public let id: ProcessID
    public var displayName: String
    public var executablePath: String
    public var industryTag: IndustryTag

    public init(
        id: ProcessID,
        displayName: String,
        executablePath: String,
        industryTag: IndustryTag = .unknown
    ) {
        self.id = id
        self.displayName = displayName
        self.executablePath = executablePath
        self.industryTag = industryTag
    }
}
