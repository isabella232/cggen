// Copyright (c) 2018 Yandex LLC. All rights reserved.
// Author: Alexander Skvortsov <askvortsov@yandex-team.ru>

import CoreGraphics
import PDFParse

struct ObjcCGGenerator: CoreGraphicsGenerator {
  let params: GenerationParams
  let headerImportPath: String?

  func filePreamble() -> String {
    let importLine: String
    if let headerImportPath = headerImportPath {
      importLine = "#import \"\(headerImportPath)\""
    } else {
      importLine = params.moduleImport("CoreGraphics")
    }
    let foundationImport = params.moduleImport("Foundation")
    return [
      importLine,
      "",
      foundationImport,
      "\n",
    ].joined(separator: "\n")
  }

  func generateImageFunction(image: Image) -> String {
    var lines: [String] = []
    lines += funcStart(imageName: image.name)
    lines += image.route.steps.flatMap {
      command(step: $0,
              gradients: image.route.gradients)
    }
    lines += [
      "  CGColorSpaceRelease(\(rgbColorSpaceVarName));",
      "}"
    ]
    lines += params.descriptorLines(for: image)

    return lines.joined(separator: "\n")
  }

  func fileEnding() -> String {
    return ""
  }
}

extension ObjcCGGenerator {
  private func funcStart(imageName: String) -> [String] {
    return [
      params.style.drawingHandlerPrefix + ObjCGen.functionDef(imageName: imageName.upperCamelCase, prefix: params.prefix),
      "  CGColorSpaceRef \(rgbColorSpaceVarName) = CGColorSpaceCreateDeviceRGB();",
    ]
  }
}

private extension GenerationParams.Style {
  var drawingHandlerPrefix: String {
    switch self {
    case .plain:
      return ""
    case .swiftFriendly:
      return "static "
    }
  }
}

private extension GenerationParams {
  private func funcName(imageName: String) -> String {
    return ObjCGen.functionName(imageName: imageName.upperCamelCase, prefix: prefix)
  }

  func descriptorLines(for image: Image) -> [String] {
    switch style {
    case .plain:
      return []
    case .swiftFriendly:
      let size = image.route.boundingRect.size
      return [
        "const \(descriptorTypename) \(descriptorName(for: image)) = {",
        "  { (CGFloat)\(size.width), (CGFloat)\(size.height) },",
        "  \(funcName(imageName: image.name))",
        "};"
      ]
    }
  }
}

private func cmd(_ name: String, _ args: String? = nil) -> String {
  let argStr: String
  if let args = args {
    argStr = ", \(args)"
  } else {
    argStr = ""
  }
  return "  CGContext\(name)(context\(argStr));"
}

private func cmd(_ name: String, points: [CGPoint]) -> String {
  return cmd(name, points.map { "(CGFloat)\($0.x), (CGFloat)\($0.y)" }.joined(separator: ", "))
}

private func cmd(_ name: String, rect: CGRect) -> String {
  let w = cmd(name, "CGRectMake((CGFloat)\(rect.x), (CGFloat)\(rect.y), (CGFloat)\(rect.size.width), (CGFloat)\(rect.size.height))")
  return w
}

private func cmd(_ name: String, float: CGFloat) -> String {
  return cmd(name, "(CGFloat)\(float)")
}

private let rgbColorSpaceVarName = "rgbColorSpace"
private var uniqColorID = 0
private func acquireUniqID() -> Int {
  let uid = uniqColorID
  uniqColorID += 1
  return uid
}

private func with(colors: [RGBAColor], block: ([String]) -> [String]) -> [String] {
  let colorNamesAndLines = colors.map { define(color: $0) }
  let colorNames = colorNamesAndLines.map { $0.0 }
  let colorDefLines = colorNamesAndLines.map { $0.1 }
  let releaseLines = colorNames.map { release(colorVarName: $0) }
  return colorDefLines + block(colorNames) + releaseLines
}

private func define(color: RGBAColor) -> (String, String) {
  let colorVarName = "color\(acquireUniqID())"
  let createColor = "  CGColorRef \(colorVarName) = CGColorCreate(\(rgbColorSpaceVarName), (CGFloat []){(CGFloat)\(color.red), (CGFloat)\(color.green), (CGFloat)\(color.blue), (CGFloat)\(color.alpha)});"
  return (colorVarName, createColor)
}

private func release(colorVarName: String) -> String {
  return "  CGColorRelease(\(colorVarName));"
}

private func cmd(_ name: String, color: RGBAColor) -> [String] {
  let (colorVarName, createColor) = define(color: color)
  let cmdStr = cmd(name, "\(colorVarName)")
  let releaseLine = release(colorVarName: colorVarName)
  return [createColor, cmdStr, releaseLine]
}

func command(step: DrawStep, gradients: [String: Gradient]) -> [String] {
  switch step {
  case .saveGState:
    return [cmd("SaveGState")]
  case .restoreGState:
    return [cmd("RestoreGState")]
  case let .moveTo(p):
    return [cmd("MoveToPoint", points: [p])]
  case let .curve(c1, c2, end):
    return [cmd("AddCurveToPoint", points: [c1, c2, end])]
  case let .line(p):
    return [cmd("AddLineToPoint", points: [p])]
  case .closePath:
    return [cmd("ClosePath")]
  case let .clip(rule):
    switch rule {
    case .winding:
      return [cmd("Clip")]
    case .evenOdd:
      return [cmd("EOClip")]
    }
  case .endPath:
    return []
  case let .flatness(flatness):
    return [cmd("SetFlatness", float: flatness)]
  case .fillColorSpace:
    return []
  case let .appendRectangle(rect):
    return [cmd("AddRect", rect: rect)]
  case let .fill(color, rule):
    let colorCmd = cmd("SetFillColorWithColor", color: color)
    let fillCmd: String
    switch rule {
    case .winding:
      fillCmd = cmd("FillPath")
    case .evenOdd:
      fillCmd = cmd("EOFillPath")
    }
    return colorCmd + [fillCmd]
  case .strokeColorSpace:
    return []
  case let .concatCTM(transform):
    return [cmd("ConcatCTM", "CGAffineTransformMake(\(transform.a), \(transform.b), \(transform.c), \(transform.d), \(transform.tx), \(transform.ty))")]
  case let .lineWidth(w):
    return [cmd("SetLineWidth", float: w)]
  case let .stroke(color):
    return cmd("SetStrokeColorWithColor", color: color) + [cmd("StrokePath")]
  case .colorRenderingIntent:
    return []
  case .parametersFromGraphicsState:
    return []
  case let .paintWithGradient(gradientKey):
    let gradient = gradients[gradientKey]!
    let colors = gradient.locationAndColors.map { $0.1 }
    let locations = gradient.locationAndColors.map { $0.0 }
    let lines = with(colors: colors) { (colorNames) -> [String] in
      let colorString = colorNames.map { "(__bridge id)\($0)" }.joined(separator: ", ")
      let colorsArrayVarName = "colors\(acquireUniqID())"
      let colorArray = "  CFArrayRef \(colorsArrayVarName) = CFBridgingRetain(@[ \(colorString) ]);"
      let locationList = locations.map { "(CGFloat)\($0)" }.joined(separator: ", ")
      let locationArray = "(CGFloat []){\(locationList)}"
      let gradientName = "gradient\(acquireUniqID())"
      let gradientDef = "  CGGradientRef \(gradientName) = CGGradientCreateWithColors(\(rgbColorSpaceVarName), \(colorsArrayVarName), \(locationArray));"
      let colorArrayRelease = "  CFRelease(\(colorsArrayVarName));"

      var optionsStrings: [String] = []
      if gradient.options.contains(.drawsBeforeStartLocation) {
        optionsStrings.append("kCGGradientDrawsBeforeStartLocation")
      }
      if gradient.options.contains(.drawsAfterEndLocation) {
        optionsStrings.append("kCGGradientDrawsAfterEndLocation")
      }
      if optionsStrings.isEmpty {
        optionsStrings.append("0")
      }
      let optionsVarName = "gradientOptions\(acquireUniqID())"
      let optionsLine = "  CGGradientDrawingOptions \(optionsVarName) = (CGGradientDrawingOptions)(\(optionsStrings.joined(separator: " | ")));"
      let startPoint = "CGPointMake((CGFloat)\(gradient.startPoint.x), (CGFloat)\(gradient.startPoint.y))"
      let endPoint = "CGPointMake((CGFloat)\(gradient.endPoint.x), (CGFloat)\(gradient.endPoint.y))"
      let drawGradientLine = "  CGContextDrawLinearGradient(context, \(gradientName), \(startPoint), \(endPoint), \(optionsVarName));"
      let releaseGradient = "  CGGradientRelease(\(gradientName));"
      return [colorArray, gradientDef, colorArrayRelease, optionsLine, drawGradientLine, releaseGradient]
    }
    return lines
  case let .dash(pattern):
    let args = "\(pattern.phase), \(ObjCGen.cgFloatArray(pattern.lengths)), \(pattern.lengths.count)"
    return [cmd("SetLineDash", args)]
  case let .subroute(route):
    return route.steps.flatMap {
      command(step: $0, gradients: route.gradients)
    }
  case let .clipToRect(rect):
    return [cmd("ClipToRect", rect: rect)]
  case .beginTransparencyLayer:
    return [cmd("BeginTransparencyLayer", "NULL")]
  case .endTransparencyLayer:
    return [cmd("EndTransparencyLayer")]
  case let .globalAlpha(a):
    return [cmd("SetAlpha", float: a)]
  }
}
