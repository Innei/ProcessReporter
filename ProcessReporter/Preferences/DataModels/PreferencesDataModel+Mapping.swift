//
//  PreferencesDataModel+Mapping.swift
//  ProcessReporter
//
//  Created by Innei on 2025/4/21.
//
import Foundation
import RxCocoa
import RxSwift

extension PreferencesDataModel {
	@UserDefaultsRelay("mappingList", defaultValue: MappingList(mappings: []))
	static var mappingList: BehaviorRelay<MappingList>
}

extension PreferencesDataModel {
	enum MappingType: String, CaseIterable, DictionaryConvertible, UserDefaultsJSONStorable, DictionaryConvertibleDelegate {
		static func fromDictionary(_ dict: Any) -> MappingType {
			guard let rawValue = dict as? String else { return .processApplicationIdentifier }
			return self.init(rawValue: rawValue) ?? .processApplicationIdentifier
		}
	 
		static func fromStorable(_ value: Any?) -> MappingType? {
			guard let rawValue = value as? String else { return nil }
			return MappingType(rawValue: rawValue)
		}
	 
		func toStorable() -> Any? {
			return rawValue
		}
	 
		func toDictionary() -> Any {
			return rawValue
		}

		case processApplicationIdentifier = "process_application_identifier"
		case processName = "process_name"
		case mediaProcessApplicationIdentifier = "media_process_application_identifier"
		case mediaProcessName = "media_process_name"
		
		func toCopyable() -> String {
			switch self {
				case .processApplicationIdentifier:
					return "Process Application Identifier"
				case .mediaProcessName:
					return "Media Process Name"
				case .mediaProcessApplicationIdentifier:
					return "Media Process Application Identifier"
				case .processName:
					return "Process Name"
			}
		}
	}

	struct Mapping: DictionaryConvertible, UserDefaultsJSONStorable, Identifiable, Equatable {
		var id: String {
			"\(type.rawValue.count)#\(type.rawValue)\(from.count)#\(from)\(to.count)#\(to)"
		}
		
		static func fromDictionary(_ dict: Any) -> Mapping {
			return fromDictionaryIfValid(dict)
				?? Mapping(type: .processApplicationIdentifier, from: "", to: "")
		}

		fileprivate static func fromDictionaryIfValid(_ value: Any) -> Mapping? {
			guard let dictionary = value as? [String: Any],
			      let rawType = dictionary["type"] as? String,
			      let type = MappingType(rawValue: rawType),
			      let from = dictionary["from"] as? String,
			      let to = dictionary["to"] as? String,
			      !from.isEmpty,
			      !to.isEmpty
			else {
				return nil
			}
			return Mapping(type: type, from: from, to: to)
		}
	 
		let type: MappingType
		let from: String
		let to: String
		
		static func == (lhs: Mapping, rhs: Mapping) -> Bool {
			return lhs.type == rhs.type && lhs.from == rhs.from && lhs.to == rhs.to
		}
	}

	struct MappingList: DictionaryConvertible, UserDefaultsJSONStorable, DictionaryConvertibleDelegate {
		func toDictionary() -> Any {
			return mappings.map { $0.toDictionary() }
		}
	 
		static func fromDictionary(_ dict: Any) -> MappingList {
			guard let dictionaries = dict as? [[String: Any]] else {
				return MappingList(mappings: [])
			}
			let mappings = dictionaries.compactMap(Mapping.fromDictionaryIfValid)
			return MappingList(mappings: mappings)
		}
	 
		static func fromStorable(_ value: Any?) -> MappingList? {
			guard let value else { return nil }
			if let dictionaries = value as? [[String: Any]] {
				return fromDictionary(dictionaries)
			}
			// Accept an older JSON-string representation if one exists.
			if let string = value as? String,
			   let data = string.data(using: .utf8),
			   let decoded = try? JSONDecoder().decode(MappingList.self, from: data)
			{
				return MappingList(
					mappings: decoded.mappings.filter { !$0.from.isEmpty && !$0.to.isEmpty })
			}
			return nil
		}
	 
		func toStorable() -> Any? {
			return toDictionary()
		}
	 
		private var mappings: [Mapping] = []
	 
		init(mappings: [Mapping]) {
			self.mappings = mappings
		}
	 
		func getList() -> [Mapping] {
			return mappings
		}

		@discardableResult
		@MainActor
		func addMapping(_ mapping: Mapping) -> Bool {
			guard !mappings.contains(mapping) else { return false }
			PreferencesDataModel.shared.mappingList.accept(
				MappingList(mappings: mappings + [mapping])
			)
			return true
		}
		
		@MainActor
		func removeMapping(_ mappings: [Mapping]) {
			PreferencesDataModel.shared.mappingList.accept(
				MappingList(mappings: self.mappings.filter { item in
					!mappings.contains(where: { $0 == item })
				})
			)
		}

		@discardableResult
		@MainActor
		func editMapping(_ mapping: Mapping, for index: Int) -> Bool {
			guard mappings.indices.contains(index),
			      !mappings.enumerated().contains(where: { offset, item in
				      offset != index && item == mapping
			      })
			else { return false }
			PreferencesDataModel.shared.mappingList.accept(
				MappingList(mappings: mappings.enumerated().map { i, item in
					i == index ? mapping : item
				})
			)
			return true
		}
	}
}
