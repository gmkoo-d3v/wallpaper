import Foundation

enum ManifestSchemaResource {
    static let directoryName = "schemas"
    static let fileName = "wallpaper-native-v2.schema.json"

    static func loadText(projectRoot: URL? = ProjectPaths.findCatalogProjectRoot()) throws -> String {
        for candidate in candidateURLs(projectRoot: projectRoot) {
            guard FileManager.default.fileExists(atPath: candidate.path) else { continue }
            return try String(contentsOf: candidate, encoding: .utf8)
        }
        throw EngineError.asset("Manifest schema resource missing: \(fileName)")
    }

    static func loadJSON(projectRoot: URL? = ProjectPaths.findCatalogProjectRoot()) throws -> [String: Any] {
        let schemaText = try loadText(projectRoot: projectRoot)
        guard let schema = try JSONSerialization.jsonObject(with: Data(schemaText.utf8)) as? [String: Any] else {
            throw EngineError.asset("Manifest schema resource is not a JSON object: \(fileName)")
        }
        return schema
    }

    static func validateManifest(at manifestURL: URL, projectRoot: URL? = ProjectPaths.findCatalogProjectRoot()) throws {
        let schema = try loadJSON(projectRoot: projectRoot)
        let manifestData = try Data(contentsOf: manifestURL)
        try validateManifestData(manifestData, schema: schema)
    }

    static func validateManifestData(
        _ manifestData: Data,
        projectRoot: URL? = ProjectPaths.findCatalogProjectRoot()
    ) throws {
        let schema = try loadJSON(projectRoot: projectRoot)
        try validateManifestData(manifestData, schema: schema)
    }

    private static func validateManifestData(_ manifestData: Data, schema: [String: Any]) throws {
        let manifestJSON = try JSONSerialization.jsonObject(with: manifestData)
        try JSONSchemaSubsetValidator(rootSchema: schema).validate(manifestJSON, path: "$")
    }

    private static func candidateURLs(projectRoot: URL?) -> [URL] {
        var urls: [URL] = []
        if let resourceURL = Bundle.main.resourceURL {
            urls.append(resourceURL.appendingPathComponent(directoryName).appendingPathComponent(fileName))
        }
        if let projectRoot {
            urls.append(
                projectRoot
                    .appendingPathComponent("apps/MacWallpaperEngine/Resources")
                    .appendingPathComponent(directoryName)
                    .appendingPathComponent(fileName)
            )
        }
        return urls
    }
}

private struct JSONSchemaSubsetValidator {
    let rootSchema: [String: Any]

    func validate(_ value: Any, path: String) throws {
        try validate(value, schema: rootSchema, path: path, depth: 0)
    }

    private func validate(_ value: Any, schema: [String: Any], path: String, depth: Int) throws {
        guard depth < 64 else {
            throw EngineError.manifest("Schema validation recursion limit exceeded at \(path)")
        }

        if let ref = schema["$ref"] as? String {
            try validate(value, schema: try resolve(ref), path: path, depth: depth + 1)
            return
        }

        if let allOf = schema["allOf"] as? [[String: Any]] {
            for child in allOf {
                try validate(value, schema: child, path: path, depth: depth + 1)
            }
        }

        if let anyOf = schema["anyOf"] as? [[String: Any]] {
            var matched = false
            for child in anyOf {
                if (try? validate(value, schema: child, path: path, depth: depth + 1)) != nil {
                    matched = true
                    break
                }
            }
            guard matched else {
                throw EngineError.manifest("Schema anyOf failed at \(path)")
            }
        }

        if let ifSchema = schema["if"] as? [String: Any],
           (try? validate(value, schema: ifSchema, path: path, depth: depth + 1)) != nil,
           let thenSchema = schema["then"] as? [String: Any] {
            try validate(value, schema: thenSchema, path: path, depth: depth + 1)
        }

        if let notSchema = schema["not"] as? [String: Any],
           (try? validate(value, schema: notSchema, path: path, depth: depth + 1)) != nil {
            throw EngineError.manifest("Schema not failed at \(path)")
        }

        if let expected = schema["const"], !jsonValue(value, equals: expected) {
            throw EngineError.manifest("Schema const mismatch at \(path)")
        }

        if let enumValues = schema["enum"] as? [Any],
           enumValues.contains(where: { jsonValue(value, equals: $0) }) == false {
            throw EngineError.manifest("Schema enum mismatch at \(path)")
        }

        if let type = schema["type"] as? String {
            try validateType(type, value: value, path: path)
        }

        if let object = value as? [String: Any] {
            try validateObject(object, schema: schema, path: path, depth: depth)
        }
        if let array = value as? [Any] {
            try validateArray(array, schema: schema, path: path, depth: depth)
        }
        if let string = value as? String {
            try validateString(string, schema: schema, path: path)
        }
        if jsonNumber(value) != nil {
            try validateNumber(value, schema: schema, path: path)
        }
    }

    private func validateObject(_ object: [String: Any], schema: [String: Any], path: String, depth: Int) throws {
        if let required = schema["required"] as? [String] {
            for key in required where object[key] == nil {
                throw EngineError.manifest("Schema required property \(key) missing at \(path)")
            }
        }

        let properties = schema["properties"] as? [String: [String: Any]] ?? [:]
        if schema["additionalProperties"] as? Bool == false {
            let allowed = Set(properties.keys)
            let unknown = object.keys.filter { allowed.contains($0) == false }.sorted()
            guard unknown.isEmpty else {
                throw EngineError.manifest("Schema unknown property \(unknown[0]) at \(path)")
            }
        }

        for (key, propertySchema) in properties {
            guard let child = object[key] else { continue }
            try validate(child, schema: propertySchema, path: "\(path).\(key)", depth: depth + 1)
        }
    }

    private func validateArray(_ array: [Any], schema: [String: Any], path: String, depth: Int) throws {
        if let minItems = schema["minItems"] as? Int, array.count < minItems {
            throw EngineError.manifest("Schema minItems failed at \(path)")
        }
        if let maxItems = schema["maxItems"] as? Int, array.count > maxItems {
            throw EngineError.manifest("Schema maxItems failed at \(path)")
        }

        if let prefixItems = schema["prefixItems"] as? [[String: Any]] {
            for (index, childSchema) in prefixItems.enumerated() where index < array.count {
                try validate(array[index], schema: childSchema, path: "\(path)[\(index)]", depth: depth + 1)
            }
        }

        if let items = schema["items"] as? Bool, items == false, array.count > (schema["prefixItems"] as? [Any] ?? []).count {
            throw EngineError.manifest("Schema additional array item at \(path)")
        }

        if let itemSchema = schema["items"] as? [String: Any] {
            for (index, child) in array.enumerated() {
                try validate(child, schema: itemSchema, path: "\(path)[\(index)]", depth: depth + 1)
            }
        }
    }

    private func validateString(_ string: String, schema: [String: Any], path: String) throws {
        if let minLength = schema["minLength"] as? Int, string.count < minLength {
            throw EngineError.manifest("Schema minLength failed at \(path)")
        }
        if let pattern = schema["pattern"] as? String,
           string.range(of: pattern, options: .regularExpression) == nil {
            throw EngineError.manifest("Schema pattern mismatch at \(path)")
        }
    }

    private func validateNumber(_ value: Any, schema: [String: Any], path: String) throws {
        guard let number = jsonNumber(value) else { return }
        if let minimum = schema["minimum"] as? NSNumber, number < minimum.doubleValue {
            throw EngineError.manifest("Schema minimum failed at \(path)")
        }
        if let maximum = schema["maximum"] as? NSNumber, number > maximum.doubleValue {
            throw EngineError.manifest("Schema maximum failed at \(path)")
        }
        if let exclusiveMinimum = schema["exclusiveMinimum"] as? NSNumber, number <= exclusiveMinimum.doubleValue {
            throw EngineError.manifest("Schema exclusiveMinimum failed at \(path)")
        }
    }

    private func validateType(_ type: String, value: Any, path: String) throws {
        let valid: Bool
        switch type {
        case "object":
            valid = value is [String: Any]
        case "array":
            valid = value is [Any]
        case "string":
            valid = value is String
        case "integer":
            valid = isJSONInteger(value)
        case "number":
            valid = jsonNumber(value) != nil
        case "boolean":
            valid = isJSONBoolean(value)
        default:
            throw EngineError.manifest("Unsupported schema type \(type) at \(path)")
        }
        guard valid else {
            throw EngineError.manifest("Schema type \(type) mismatch at \(path)")
        }
    }

    private func resolve(_ ref: String) throws -> [String: Any] {
        let prefix = "#/$defs/"
        guard ref.hasPrefix(prefix) else {
            throw EngineError.manifest("Unsupported schema ref: \(ref)")
        }
        let key = String(ref.dropFirst(prefix.count))
        guard let defs = rootSchema["$defs"] as? [String: Any],
              let schema = defs[key] as? [String: Any] else {
            throw EngineError.manifest("Missing schema ref: \(ref)")
        }
        return schema
    }

    private func jsonValue(_ lhs: Any, equals rhs: Any) -> Bool {
        switch (lhs, rhs) {
        case (let lhs as String, let rhs as String):
            return lhs == rhs
        case (let lhs as Bool, let rhs as Bool):
            return lhs == rhs
        case (let lhs as NSNumber, let rhs as NSNumber):
            return lhs == rhs
        default:
            return false
        }
    }

    private func isJSONInteger(_ value: Any) -> Bool {
        guard let number = jsonNumber(value) else { return false }
        return number.rounded(.towardZero) == number
    }

    private func jsonNumber(_ value: Any) -> Double? {
        if isJSONBoolean(value) {
            return nil
        }
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        if let double = value as? Double {
            return double
        }
        if let int = value as? Int {
            return Double(int)
        }
        return nil
    }

    private func isJSONBoolean(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else {
            return value is Bool
        }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }
}
