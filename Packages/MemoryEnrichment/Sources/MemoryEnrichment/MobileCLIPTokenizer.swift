//
//  CLIPTokenizer.swift
//  CoreMLBert
//
//  Created by Matthew Waller on 1/31/23.
//  Copyright © 2023 Hugging Face. All rights reserved.
//
//  Modified by Hugues Thomas on 5/14/24.
//
// Derived from Hugging Face swift-coreml-transformers pull request 30.

import Foundation

struct BytePair: Hashable {
    let a: String
    let b: String
    init(_ a: String, _ b: String) {
        self.a = a
        self.b = b
    }

    static func == (lhs: BytePair, rhs: BytePair) -> Bool {
        return lhs.a == rhs.a && lhs.b == rhs.b
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(a)
        hasher.combine(b)
    }
}

public enum MobileCLIPTokenizerError: Error, Equatable, Sendable {
    case invalidMerge(Int)
    case invalidPattern
    case invalidTextRange
    case missingByteEncoding(UInt8)
    case missingToken(String)
    case missingSpecialToken(String)
    case unknownTokenID(Int)
}

final class CLIPTokenizer: @unchecked Sendable {
    let bpeRanks: [BytePair: Int]
    private let encoder: [String: Int]
    private let decoder: [Int: String]
    private let regex: NSRegularExpression
    private let startToken: Int
    private let endToken: Int
    let contextLength = 77

    init(resourcesRoot: URL) throws {
        let url = resourcesRoot.appending(path: "clip-merges.txt")
        let bpeMergesTxt = try String(contentsOf: url, encoding: .utf8)
        let arr = bpeMergesTxt.split(separator: "\n").map { String($0) }
        var bpeRanks: [BytePair: Int] = [:]
        for i in 1..<arr.count {
            let tuple = arr[i].split(separator: " ").map { String($0) }
            guard tuple.count == 2 else {
                throw MobileCLIPTokenizerError.invalidMerge(i)
            }
            let bp = BytePair(tuple[0], tuple[1])
            bpeRanks[bp] = i - 1
        }
        self.bpeRanks = bpeRanks

        let vocabularyURL = resourcesRoot.appending(path: "clip-vocab.json")
        let vocabularyData = try Data(contentsOf: vocabularyURL)
        let encoder = try JSONDecoder().decode([String: Int].self, from: vocabularyData)
        self.encoder = encoder

        self.decoder = Utils.invert(encoder)
        guard let startToken = encoder["<|startoftext|>"] else {
            throw MobileCLIPTokenizerError.missingSpecialToken("start")
        }
        guard let endToken = encoder["<|endoftext|>"] else {
            throw MobileCLIPTokenizerError.missingSpecialToken("end")
        }
        self.startToken = startToken
        self.endToken = endToken
        do {
            regex = try NSRegularExpression(
                pattern:
                    "<\\|startoftext\\|>|<\\|endoftext\\|>|'s|'t|'re|'ve|'m|'ll|'d|[\\p{L}]+|[\\p{N}]|[^\\s\\p{L}\\p{N}]+",
                options: []
            )
        } catch {
            throw MobileCLIPTokenizerError.invalidPattern
        }
    }

    func byteEncode(text: String) throws -> [String] {
        let matches = regex.matches(
            in: text, options: [], range: NSRange(location: 0, length: text.utf16.count))
        let tokens = try matches.map { (match) -> String in
            guard let range = Range(match.range, in: text) else {
                throw MobileCLIPTokenizerError.invalidTextRange
            }
            return String(text[range])
        }
        return try tokens.map { token -> String in
            try Array(token.utf8).map { byte in
                guard let encoded = byteEncoder[byte] else {
                    throw MobileCLIPTokenizerError.missingByteEncoding(byte)
                }
                return encoded
            }.joined()
        }
    }

    private func getPairs(word: [String]) -> Set<BytePair> {
        guard word.count > 1 else { return [] }
        var s = Set<BytePair>()
        for i in 0..<word.count - 1 {
            let bp = BytePair(
                word[i],
                word[i + 1]
            )
            s.insert(bp)
        }
        return s
    }

    func bpe(token: String) -> String {
        if token.count <= 1 {
            return token + "</w>"
        }

        var word = Array(token).map { String($0) }
        let last = (word.last ?? "") + "</w>"
        word.removeLast()
        word.append(last)
        var pairs = Array(getPairs(word: word))
        if pairs.isEmpty {
            return token + "</w>"
        }

        while true {
            let bigrams = pairs.filter { (bp) -> Bool in bpeRanks[bp] != nil }
            if bigrams.count == 0 {
                break
            }
            guard
                let bigram = bigrams.min(by: { bp1, bp2 in
                    (bpeRanks[bp1] ?? .max) < (bpeRanks[bp2] ?? .max)
                })
            else { break }
            let first = bigram.a
            let second = bigram.b
            var newWord: [String] = []
            var i = 0
            while i < word.count {
                if let j = word[i..<word.count].firstIndex(of: first) {
                    newWord.append(contentsOf: word[i..<j])
                    i = j
                } else {
                    newWord.append(contentsOf: word[i..<word.count])
                    break
                }

                if word[i] == first && i < word.count - 1 && word[i + 1] == second {
                    newWord.append(first + second)
                    i += 2
                } else {
                    newWord.append(word[i])
                    i += 1
                }
            }
            word = newWord
            if word.count == 1 {
                break
            } else {
                pairs = Array(getPairs(word: word))
            }
        }
        return word.joined(separator: " ")
    }

    func tokenize(text: String) throws -> [String] {
        var tokens: [String] = []
        let lowercased = text.lowercased()
        for token in try self.byteEncode(text: lowercased) {
            let xx = self.bpe(token: token).split(separator: " ").map { String($0) }
            tokens.append(contentsOf: xx)
        }
        return tokens
    }

    /// Main entry point
    func encode(text: String) throws -> [Int] {
        try tokenize(text: text).map { token in
            guard let encoded = encoder[token] else {
                throw MobileCLIPTokenizerError.missingToken(token)
            }
            return encoded
        }
    }

    /// Decode
    func decode(tokens: [Int]) throws -> String {
        let text = try tokens.map { token in
            guard let decoded = decoder[token] else {
                throw MobileCLIPTokenizerError.unknownTokenID(token)
            }
            return decoded
        }.joined(separator: "")
        let utfCodepoints = try text.map { character in
            guard let byte = byteDecoder[String(character)] else {
                throw MobileCLIPTokenizerError.missingToken(String(character))
            }
            return byte
        }
        return String(decoding: utfCodepoints, as: UTF8.self)
    }

    func encodeFull(text: String) throws -> [Int] {
        let tokens = Array(try encode(text: text).prefix(contextLength - 2))

        // Create the full input tokens as a multiarray of shape 1 x contextLength
        var fullTokens = Array(repeating: 0, count: contextLength)
        fullTokens[0] = startToken
        for i in 0..<tokens.count {
            fullTokens[i + 1] = tokens[i]
        }
        fullTokens[tokens.count + 1] = endToken
        return fullTokens

    }
}
