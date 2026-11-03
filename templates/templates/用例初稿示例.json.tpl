{
  "schemaVersion": "eoffice-case-draft-1",
  "title": "登录入口示例",
  "author": "示例署名，实际使用前替换",
  "scope": "仅演示初稿内容结构，不代表任何业务已经验收。",
  "entry": "填写本轮实探取得的目标地址、菜单路径和菜单 ID。",
  "environment": "待确认",
  "dataBatch": "待确认",
  "constraints": "正式执行前确认验收标准并核验环境；不自动删除数据。",
  "permissionTesting": {"enabled": false, "reason": "仅检查匿名登录入口，不包含业务菜单或数据范围验证。"},
  "sheets": [{
    "name": "登录入口",
    "cases": [{
      "id": "DEMO-001",
      "module": "示例模块",
      "type": "功能测试",
      "priority": "P0",
      "scenario": "登录页面可展示账号和密码输入框",
      "accounts": ["A00"],
      "data": ["D00"],
      "preconditions": ["目标环境在线；无已保存登录态。"],
      "steps": ["打开本轮确认的登录地址。"],
      "expected": ["展示账号输入框、密码输入框及登录按钮。"],
      "remarks": "示例内容；正式用例需先实探并确认标准。"
    }]
  }],
  "accounts": [{
    "id": "A00", "username": "不适用", "department": "不适用", "role": "匿名",
    "scope": "不适用", "purpose": "匿名登录入口", "credential": "不适用", "checks": ["V01"]
  }],
  "data": [{
    "id": "D00", "source": "不适用", "method": "登录入口不依赖业务记录。",
    "initialState": "不适用", "mutates": "不适用", "checks": ["V01"]
  }],
  "checks": [{
    "id": "V01", "items": "账号及业务记录前置条件", "expected": "匿名入口无需业务记录。",
    "notApplicableReason": "仅检查匿名登录入口，无需登录账号或业务数据。"
  }]
}
