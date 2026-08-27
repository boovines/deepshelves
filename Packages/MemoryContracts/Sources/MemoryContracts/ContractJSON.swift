import Foundation

public enum ContractJSON {
    public static func encode<Value>(_ value: Value) throws -> Data
    where Value: Encodable & ContractValidatable {
        try value.validate()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            let style = Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: .gmt)
            try container.encode(date.formatted(style))
        }
        let encoded = try encoder.encode(value)
        let object = try JSONSerialization.jsonObject(with: encoded)
        return try JSONSerialization.data(
            withJSONObject: canonicalize(object),
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }

    public static func decode<Value>(_ type: Value.Type, from data: Data) throws -> Value
    where Value: Decodable & ContractValidatable {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let encoded = try container.decode(String.self)
            let canonicalRange = encoded.range(
                of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z$"#,
                options: .regularExpression
            )
            guard canonicalRange != nil else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Expected canonical RFC 3339 UTC timestamp with milliseconds"
                )
            }
            let style = Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: .gmt)
            do {
                return try style.parse(encoded)
            } catch {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Expected RFC 3339 UTC timestamp with fractional seconds"
                )
            }
        }
        let value = try decoder.decode(type, from: data)
        try value.validate()
        return value
    }

    public static func roundTrip<Value>(_ type: Value.Type, fixture data: Data) throws -> Data
    where Value: Codable & ContractValidatable {
        try encode(decode(type, from: data))
    }

    private static func canonicalize(_ object: Any) -> Any {
        if let dictionary = object as? [String: Any] {
            return dictionary.mapValues(canonicalize)
        }
        if let array = object as? [Any] {
            return array.map(canonicalize)
        }
        if let string = object as? String,
            string.count == 36,
            UUID(uuidString: string) != nil
        {
            return string.lowercased()
        }
        return object
    }
}
