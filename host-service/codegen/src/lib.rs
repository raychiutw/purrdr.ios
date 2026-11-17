//! 由主機服務協定的 JSON Schema 產生 Rust 與 Swift 型別。
//!
//! 只支援協定用到的子集合(`$defs` 底下):
//! - 物件:`type: object`,`properties` 為 string／integer／boolean／`$ref`／array;不在 `required` 的欄位是 optional。
//!   `type` 欄位若是 `const`,當作訊息種類，不產生欄位。
//! - 字串列舉:`type: string` + `enum`。
//! - 訊息聯集:`oneOf` 只列 `$ref`,每個都是帶 `type` const 的物件。
//!   有變體標 `x-write: true` 時，聯集多產生 `is_write()`(Swift `isWrite`)。

use serde_json::Value;

/// 產生的檔案路徑(相對 repo 根目錄)。
pub const SCHEMA_PATH: &str = "protocol/host-service.schema.json";
pub const RUST_OUTPUT_PATH: &str = "host-service/service/src/protocol.rs";
pub const SWIFT_OUTPUT_PATH: &str = "src/PurrdrCore/HostServiceProtocol.swift";

const HEADER: &str = "由 protocol/host-service.schema.json 產生，不要手動修改。重新產生:cd host-service && cargo run -p protocol-codegen";

#[derive(Debug, Clone, PartialEq)]
enum FieldType {
    String,
    Integer,
    Boolean,
    Reference(String),
    Array(Box<FieldType>),
}

#[derive(Debug, Clone)]
struct Field {
    json_name: String,
    description: Option<String>,
    field_type: FieldType,
    required: bool,
}

#[derive(Debug, Clone)]
enum Definition {
    Object {
        name: String,
        description: Option<String>,
        fields: Vec<Field>,
    },
    StringEnum {
        name: String,
        description: Option<String>,
        values: Vec<String>,
    },
    Union {
        name: String,
        description: Option<String>,
        variants: Vec<(String, String)>,
        /// 標 `x-write: true` 的變體(寫入類訊息)。
        write_variants: Vec<String>,
    },
}

/// schema 解析後的模型。
pub struct Protocol {
    version: i64,
    definitions: Vec<Definition>,
}

impl Protocol {
    /// 解析 schema;用到子集合以外的寫法時回傳錯誤。
    pub fn parse(schema: &Value) -> Result<Self, String> {
        let version = schema["x-protocol-version"].as_i64().ok_or("缺少 x-protocol-version")?;
        let definitions_json = schema["$defs"].as_object().ok_or("缺少 $defs")?;
        let mut definitions = Vec::new();
        for (name, definition) in definitions_json {
            definitions.push(parse_definition(name, definition, schema)?);
        }
        Ok(Protocol { version, definitions })
    }

    /// 產生 Rust(serde)型別。
    pub fn rust(&self) -> String {
        let mut output = format!("//! {HEADER}\n\nuse serde::{{Deserialize, Serialize}};\n\n");
        output += &format!(
            "/// 協定版本(schema 的 `x-protocol-version`)。\npub const PROTOCOL_VERSION: i64 = {};\n",
            self.version
        );
        for definition in &self.definitions {
            output += "\n";
            output += &rust_definition(definition);
        }
        output
    }

    /// 產生 Swift(Codable)型別，放在 `HostServiceProtocol` 命名空間;只用 Foundation。
    pub fn swift(&self) -> String {
        let mut output = format!("// {HEADER}\n\nimport Foundation\n\n");
        output += "/// 主機服務協定(ADR-0010)的訊息型別。\npublic enum HostServiceProtocol {\n";
        output += &format!(
            "    /// 協定版本(schema 的 `x-protocol-version`)。\n    public static let version = {}\n}}\n",
            self.version
        );
        for definition in &self.definitions {
            output += "\n";
            output += &swift_definition(definition);
        }
        output
    }
}

fn description_of(value: &Value) -> Option<String> {
    value["description"].as_str().map(str::to_owned)
}

fn reference_name(reference: &str) -> Result<String, String> {
    reference
        .strip_prefix("#/$defs/")
        .map(str::to_owned)
        .ok_or_else(|| format!("不支援的 $ref:{reference}"))
}

fn parse_definition(name: &str, definition: &Value, schema: &Value) -> Result<Definition, String> {
    let description = description_of(definition);
    if let Some(variants) = definition["oneOf"].as_array() {
        let mut parsed = Vec::new();
        let mut write_variants = Vec::new();
        for variant in variants {
            let target = reference_name(variant["$ref"].as_str().ok_or_else(|| format!("{name}:oneOf 只能列 $ref"))?)?;
            let tag = schema["$defs"][&target]["properties"]["type"]["const"]
                .as_str()
                .ok_or_else(|| format!("{name}:{target} 沒有 type const"))?;
            if schema["$defs"][&target]["x-write"].as_bool() == Some(true) {
                write_variants.push(target.clone());
            }
            parsed.push((tag.to_owned(), target));
        }
        return Ok(Definition::Union {
            name: name.to_owned(),
            description,
            variants: parsed,
            write_variants,
        });
    }
    match definition["type"].as_str() {
        Some("string") => {
            let values = definition["enum"].as_array().ok_or_else(|| format!("{name}:字串型別必須是 enum"))?;
            let values = values
                .iter()
                .map(|value| value.as_str().map(str::to_owned).ok_or_else(|| format!("{name}:enum 值必須是字串")))
                .collect::<Result<_, _>>()?;
            Ok(Definition::StringEnum {
                name: name.to_owned(),
                description,
                values,
            })
        }
        Some("object") => {
            let required: Vec<&str> = definition["required"]
                .as_array()
                .map(|items| items.iter().filter_map(Value::as_str).collect())
                .unwrap_or_default();
            let properties = definition["properties"].as_object().ok_or_else(|| format!("{name}:物件沒有 properties"))?;
            let mut fields = Vec::new();
            for (json_name, property) in properties {
                if json_name == "type" {
                    property["const"].as_str().ok_or_else(|| format!("{name}:type 必須是 const"))?;
                    continue;
                }
                fields.push(Field {
                    json_name: json_name.clone(),
                    description: description_of(property),
                    field_type: parse_field_type(property).map_err(|error| format!("{name}.{json_name}:{error}"))?,
                    required: required.contains(&json_name.as_str()),
                });
            }
            Ok(Definition::Object {
                name: name.to_owned(),
                description,
                fields,
            })
        }
        other => Err(format!("{name}:不支援的型別 {other:?}")),
    }
}

fn parse_field_type(property: &Value) -> Result<FieldType, String> {
    if let Some(reference) = property["$ref"].as_str() {
        return Ok(FieldType::Reference(reference_name(reference)?));
    }
    match property["type"].as_str() {
        Some("string") => Ok(FieldType::String),
        Some("integer") => Ok(FieldType::Integer),
        Some("boolean") => Ok(FieldType::Boolean),
        Some("array") => Ok(FieldType::Array(Box::new(parse_field_type(&property["items"])?))),
        other => Err(format!("不支援的欄位型別 {other:?}")),
    }
}

fn pascal_case(text: &str) -> String {
    text.split(['_', '.', '-'])
        .filter(|word| !word.is_empty())
        .map(|word| {
            let mut characters = word.chars();
            characters
                .next()
                .map(|first| first.to_ascii_uppercase().to_string() + characters.as_str())
                .unwrap_or_default()
        })
        .collect()
}

fn camel_case(text: &str) -> String {
    let pascal = pascal_case(text);
    let mut characters = pascal.chars();
    characters
        .next()
        .map(|first| first.to_ascii_lowercase().to_string() + characters.as_str())
        .unwrap_or_default()
}

fn doc_comment(description: &Option<String>, indent: &str) -> String {
    description.as_ref().map(|text| format!("{indent}/// {text}\n")).unwrap_or_default()
}

fn rust_type(field_type: &FieldType) -> String {
    match field_type {
        FieldType::String => "String".into(),
        FieldType::Integer => "i64".into(),
        FieldType::Boolean => "bool".into(),
        FieldType::Reference(name) => name.clone(),
        FieldType::Array(item) => format!("Vec<{}>", rust_type(item)),
    }
}

fn rust_definition(definition: &Definition) -> String {
    match definition {
        Definition::Union {
            name,
            description,
            variants,
            write_variants,
        } => {
            let mut output = doc_comment(description, "");
            output += "#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]\n#[serde(tag = \"type\")]\n";
            output += &format!("pub enum {name} {{\n");
            for (tag, target) in variants {
                output += &format!("    #[serde(rename = \"{tag}\")]\n    {target}({target}),\n");
            }
            output += "}\n";
            if !write_variants.is_empty() {
                output += &format!("\nimpl {name} {{\n");
                output += "    /// 寫入類訊息(schema 的 `x-write`);唯讀裝置送出時被拒絕。\n";
                let patterns: Vec<String> = write_variants.iter().map(|target| format!("{name}::{target}(_)")).collect();
                output += &format!("    pub fn is_write(&self) -> bool {{\n        matches!(self, {})\n    }}\n}}\n", patterns.join(" | "));
            }
            output
        }
        Definition::StringEnum { name, description, values } => {
            let mut output = doc_comment(description, "");
            output += "#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]\n";
            output += &format!("pub enum {name} {{\n");
            for value in values {
                output += &format!("    #[serde(rename = \"{value}\")]\n    {},\n", pascal_case(value));
            }
            output + "}\n"
        }
        Definition::Object { name, description, fields, .. } => {
            let mut output = doc_comment(description, "");
            output += "#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]\n";
            output += &format!("pub struct {name} {{\n");
            for field in fields {
                output += &doc_comment(&field.description, "    ");
                let field_type = rust_type(&field.field_type);
                if field.required {
                    output += &format!("    pub {}: {field_type},\n", field.json_name);
                } else {
                    output += "    #[serde(default, skip_serializing_if = \"Option::is_none\")]\n";
                    output += &format!("    pub {}: Option<{field_type}>,\n", field.json_name);
                }
            }
            output + "}\n"
        }
    }
}

fn swift_type(field_type: &FieldType) -> String {
    match field_type {
        FieldType::String => "String".into(),
        FieldType::Integer => "Int".into(),
        FieldType::Boolean => "Bool".into(),
        FieldType::Reference(name) => name.clone(),
        FieldType::Array(item) => format!("[{}]", swift_type(item)),
    }
}

fn swift_identifier(name: &str) -> String {
    const KEYWORDS: [&str; 12] = [
        "default", "case", "class", "enum", "func", "import", "in", "let", "protocol", "self", "struct", "var",
    ];
    if KEYWORDS.contains(&name) { format!("`{name}`") } else { name.to_owned() }
}

fn swift_definition(definition: &Definition) -> String {
    let mut output = "extension HostServiceProtocol {\n".to_owned();
    match definition {
        Definition::Union {
            name,
            description,
            variants,
            write_variants,
        } => {
            output += &doc_comment(description, "    ");
            output += &format!("    public enum {name}: Codable, Sendable, Equatable {{\n");
            for (_, target) in variants {
                output += &format!("        case {}({target})\n", swift_identifier(&camel_case(target)));
            }
            output += "\n        private enum TypeKey: String, CodingKey {\n            case type\n        }\n\n";
            output += "        public init(from decoder: any Decoder) throws {\n";
            output += "            let container = try decoder.container(keyedBy: TypeKey.self)\n";
            output += "            let type = try container.decode(String.self, forKey: .type)\n";
            output += "            switch type {\n";
            for (tag, target) in variants {
                output += &format!("            case \"{tag}\": self = .{}(try {target}(from: decoder))\n", camel_case(target));
            }
            output += "            default:\n";
            output +=
                "                throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: \"unknown message type \\(type)\")\n";
            output += "            }\n        }\n\n";
            output += "        public func encode(to encoder: any Encoder) throws {\n";
            output += "            var container = encoder.container(keyedBy: TypeKey.self)\n";
            output += "            switch self {\n";
            for (tag, target) in variants {
                output += &format!("            case .{}(let message):\n", camel_case(target));
                output += &format!("                try container.encode(\"{tag}\", forKey: .type)\n");
                output += "                try message.encode(to: encoder)\n";
            }
            output += "            }\n        }\n";
            if !write_variants.is_empty() {
                output += "\n        /// 寫入類訊息(schema 的 `x-write`);唯讀裝置送出時被拒絕。\n";
                output += "        public var isWrite: Bool {\n            switch self {\n";
                let cases: Vec<String> = write_variants.iter().map(|target| format!(".{}", camel_case(target))).collect();
                output += &format!("            case {}: return true\n", cases.join(", "));
                if write_variants.len() < variants.len() {
                    output += "            default: return false\n";
                }
                output += "            }\n        }\n";
            }
            output += "    }\n";
        }
        Definition::StringEnum { name, description, values } => {
            output += &doc_comment(description, "    ");
            output += &format!("    public enum {name}: String, Codable, Sendable, CaseIterable {{\n");
            for value in values {
                let case_name = camel_case(value);
                if case_name == *value {
                    output += &format!("        case {}\n", swift_identifier(&case_name));
                } else {
                    output += &format!("        case {} = \"{value}\"\n", swift_identifier(&case_name));
                }
            }
            output += "    }\n";
        }
        Definition::Object { name, description, fields, .. } => {
            output += &doc_comment(description, "    ");
            output += &format!("    public struct {name}: Codable, Sendable, Equatable {{\n");
            for field in fields {
                output += &doc_comment(&field.description, "        ");
                let optional = if field.required { "" } else { "?" };
                output += &format!(
                    "        public var {}: {}{optional}\n",
                    swift_identifier(&camel_case(&field.json_name)),
                    swift_type(&field.field_type)
                );
            }
            let parameters: Vec<String> = fields
                .iter()
                .map(|field| {
                    let default = if field.required { "" } else { "? = nil" };
                    format!(
                        "{}: {}{default}",
                        swift_identifier(&camel_case(&field.json_name)),
                        swift_type(&field.field_type)
                    )
                })
                .collect();
            output += &format!("\n        public init({}) {{\n", parameters.join(", "));
            for field in fields {
                let property = camel_case(&field.json_name);
                output += &format!("            self.{property} = {}\n", swift_identifier(&property));
            }
            output += "        }\n";
            if !fields.is_empty() {
                output += "\n        private enum CodingKeys: String, CodingKey {\n";
                for field in fields {
                    let property = camel_case(&field.json_name);
                    if property == field.json_name {
                        output += &format!("            case {}\n", swift_identifier(&property));
                    } else {
                        output += &format!("            case {} = \"{}\"\n", swift_identifier(&property), field.json_name);
                    }
                }
                output += "        }\n";
            }
            output += "    }\n";
        }
    }
    output + "}\n"
}
