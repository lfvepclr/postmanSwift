import Foundation

struct DynamicVariable: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let example: String
    let description: String

    var token: String { "{{\(name)}}" }
}

/// Built-in `{{$name}}` values, mirroring `DynamicVariableProvider.generate`.
/// Names must stay in sync with the provider; a unit test compares both sets.
enum DynamicVariableCatalog {
    static let all: [DynamicVariable] = [
        .init(name: "$guid", example: "b7e2c1a4-5f60-4e3a-9d21-8c7f6a1b2c3d", description: "随机 UUID（小写）"),
        .init(name: "$randomUUID", example: "b7e2c1a4-5f60-4e3a-9d21-8c7f6a1b2c3d", description: "随机 UUID（与 $guid 相同）"),
        .init(name: "$timestamp", example: "1790000000", description: "当前 Unix 时间戳（秒）"),
        .init(name: "$isoTimestamp", example: "2026-10-27T12:34:56Z", description: "当前时间的 ISO 8601 字符串"),
        .init(name: "$randomInt", example: "482", description: "0–1000 的随机整数"),
        .init(name: "$randomBoolean", example: "true", description: "随机 true / false"),
        .init(name: "$randomAlphaNumeric", example: "k3n8zq1v7p0w2x5r", description: "16 位随机字母数字"),
        .init(name: "$randomHexColor", example: "#3FA9C2", description: "随机十六进制颜色"),
        .init(name: "$randomFirstName", example: "Sofia", description: "随机名"),
        .init(name: "$randomLastName", example: "Chen", description: "随机姓"),
        .init(name: "$randomFullName", example: "Sofia Chen", description: "随机全名"),
        .init(name: "$randomEmail", example: "sofia.chen@example.com", description: "随机邮箱"),
        .init(name: "$randomExampleEmail", example: "sofia.chen@example.com", description: "随机示例邮箱"),
        .init(name: "$randomUserName", example: "sofia482", description: "随机用户名"),
        .init(name: "$randomPassword", example: "V7sdK2mQp9xL4t", description: "随机密码"),
        .init(name: "$randomWord", example: "river", description: "随机单词"),
        .init(name: "$randomCity", example: "Tokyo", description: "随机城市"),
        .init(name: "$randomCountry", example: "Japan", description: "随机国家"),
        .init(name: "$randomStreetName", example: "Chen Avenue", description: "随机街道名"),
        .init(name: "$randomPhoneNumber", example: "+12025550123", description: "随机电话号码"),
        .init(name: "$randomIP", example: "192.168.10.24", description: "随机 IPv4 地址"),
        .init(name: "$randomIPV6", example: "3f2a:9c1d:77e0:0b12:5a44:8d3f:1c20:9e77", description: "随机 IPv6 地址"),
        .init(name: "$randomIPv4", example: "192.168.10.24", description: "随机 IPv4 地址（与 $randomIP 相同）"),
        .init(name: "$randomPort", example: "49152", description: "1024–65535 的随机端口"),
        .init(name: "$randomUserAgent", example: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)…", description: "随机 User-Agent"),
        .init(name: "$randomProtocol", example: "https", description: "随机 http / https"),
        .init(name: "$randomDomainName", example: "api.local", description: "随机域名"),
        .init(name: "$randomUrl", example: "https://api.local/bridge", description: "随机 URL"),
        .init(name: "$randomJobTitle", example: "Engineer", description: "随机职位"),
        .init(name: "$randomCompanyName", example: "Acme", description: "随机公司名"),
        .init(name: "$randomColor", example: "teal", description: "随机颜色名"),
        .init(name: "$randomCurrencyCode", example: "CNY", description: "随机货币代码"),
        .init(name: "$randomCurrencyName", example: "Chinese Yuan", description: "随机货币名称"),
        .init(name: "$randomCurrencySymbol", example: "¥", description: "随机货币符号"),
        .init(name: "$randomLocale", example: "zh_CN", description: "随机语言区域"),
        .init(name: "$randomLatitude", example: "31.230416", description: "随机纬度"),
        .init(name: "$randomLongitude", example: "121.473701", description: "随机经度"),
        .init(name: "$randomMonth", example: "October", description: "随机月份"),
        .init(name: "$randomWeekday", example: "Monday", description: "随机星期"),
        .init(name: "$randomPrice", example: "128.50", description: "1–1000 的随机价格"),
        .init(name: "$randomProductName", example: "Acme Bridge", description: "随机产品名"),
        .init(name: "$randomBS", example: "synergize platforms", description: "随机商业套话"),
        .init(name: "$randomAbbreviation", example: "API", description: "随机技术缩写"),
        .init(name: "$randomDateRecent", example: "2026-10-20T08:15:00Z", description: "近 30 天内的随机时间"),
        .init(name: "$randomDatePast", example: "2021-03-14T09:00:00Z", description: "过去的随机时间"),
        .init(name: "$randomDateFuture", example: "2028-05-06T18:30:00Z", description: "未来的随机时间"),
        .init(name: "$randomLoremWord", example: "harbor", description: "随机 Lorem 单词"),
        .init(name: "$randomLoremWords", example: "silver forest bridge", description: "3 个随机单词"),
        .init(name: "$randomLoremSentence", example: "River cloud stone summit.", description: "随机英文句子"),
        .init(name: "$randomLoremSentences", example: "Silver harbor meadow. Orange bridge summit.", description: "3 个随机句子"),
        .init(name: "$randomLoremParagraph", example: "River cloud stone summit. …", description: "随机段落"),
        .init(name: "$randomLoremParagraphs", example: "River cloud… \n\n Stone summit…", description: "3 个随机段落"),
        .init(name: "$randomBankAccount", example: "6222021234567890", description: "8–12 位银行账号"),
        .init(name: "$randomBankAccountName", example: "Checking", description: "银行账户类型"),
        .init(name: "$randomBankAccountRouting", example: "123456789", description: "9 位路由号"),
        .init(name: "$randomCreditCardNumber", example: "4539112233445566", description: "16 位信用卡号"),
        .init(name: "$randomCreditCardType", example: "Visa", description: "信用卡类型"),
        .init(name: "$randomCreditCardCVV", example: "423", description: "3 位 CVV"),
        .init(name: "$randomCreditCardExpiry", example: "08/29", description: "信用卡有效期"),
        .init(name: "$randomFileName", example: "river-482.json", description: "随机文件名"),
        .init(name: "$randomCommonFileName", example: "river-482.json", description: "随机常见文件名"),
        .init(name: "$randomFileType", example: "application", description: "随机文件类型"),
        .init(name: "$randomCommonFileType", example: "application", description: "随机常见文件类型"),
        .init(name: "$randomFileExt", example: "json", description: "随机文件扩展名"),
        .init(name: "$randomCommonFileExt", example: "json", description: "随机常见扩展名"),
        .init(name: "$randomDirectoryPath", example: "/exports/data", description: "随机目录路径"),
        .init(name: "$randomSemver", example: "3.8.12", description: "随机语义化版本"),
        .init(name: "$randomNanoId", example: "V1StGXR8_Z5jdHi6B-myT", description: "21 位 NanoID"),
        .init(name: "$randomMACAddress", example: "3F:2A:9C:1D:77:E0", description: "随机 MAC 地址"),
        .init(name: "$randomMimeType", example: "application/json", description: "随机 MIME 类型"),
        .init(name: "$randomAvatarImage", example: "https://example.com/avatars/b7e2c1a4.png", description: "随机头像图片 URL")
    ]

    static let byName: [String: DynamicVariable] = Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0) })
    static let supportedNames: Set<String> = Set(all.map(\.name))
}
