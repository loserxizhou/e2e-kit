// 核心工具的合成 OOXML 夹具，不读取/改写用户工作簿，不作为业务交付表格。
import { spawnSync } from 'node:child_process';
import { mkdirSync } from 'node:fs';
import { dirname } from 'node:path';

export function fixtureWorkbook(file, { ids = ['RUN-001', 'RUN-002'], passed = false, expectation = '1. 返回指定结果', note = '人工备注', role = '测试身份', dimension = 'correct', overflowRow = null, overflowColumn = null } = {}) {
  const columns = ['用例编号', '所属模块', '用例类型', '优先级', '测试场景', '前置条件', '测试步骤', '预期结果', '实测结果', '验证结果', '备注', '附件', '测试日期时间', '反馈号', '创建人', '创建时间'];
  const n = ids.length;
  const sheets = {
    '说明': [
      ['一、范围', '核心工具合成夹具'], ['二、环境', '离线'], ['三、能力', '工具'], ['四、数据', '无业务记录'], ['五、执行', '原生运行器'],
      ['六、权限模型', '权限测试：否；离线工具夹具无需业务权限'], ['七、约束', '无业务数据'], ['八、执行说明', '本批次'],
      ['九、执行统计'], ['状态', '用例数', '占比'], ['通过', passed ? n : 0], ['未通过', 0], ['未执行', passed ? 0 : n], ['合计', n],
      [], [], [], [], [], [], [], [],
      ['十、各能力用例数量'], ['能力（工作表）', '用例数'], ['工具', n], ['合计', n],
      ['十一、脚本与用例对应统计'], ['TS 文件路径', '对应模块', '覆盖用例编号', '用例数', '通过', '未通过', '未执行', '最近执行时间'],
      ['tests/工具/批次/批次.e2e.ts', '工具', ids.join('、'), n, passed ? n : 0, 0, passed ? 0 : n, passed ? '2026-11-02 16:00' : '—'], ['合计', '—', '—', n],
    ],
    '工具': [columns, ...ids.map((id) => [id, '工具', '功能测试', 'P1', `场景 ${id}`, '1. A01；D01', '1. 验证指定结果', expectation,
      passed ? '1. 实际观察指定结果' : '—', passed ? '通过' : '未执行', note, '—', passed ? '2026-11-02 16:00' : '—', '—', '工具自检', '2026-11-02 15:00'])],
    '账号矩阵': [['账号代号', '用户名 / 用户ID', '部门', '角色', '菜单及数据范围', '用途', '凭据配置项', '关联核验编号'],
      ['A01', '不适用', '不适用', role, '不适用', '离线工具不登录', '不适用', 'V01']],
    '测试数据': [['被测环境', '离线'], ['数据批次', 'fixture'],
      ['数据编号', '关联用例编号', '来源方式', '准备方法 / 脚本位置', '实际ID / 业务编码', '初始状态及权限', '是否被用例改变', '关联核验编号'],
      ['D01', ids.join('、'), '不适用', '离线工具没有业务记录', '—', '不适用', '不适用', 'V01']],
    '造数核验': [['核验编号', '核验对象', '检查项', '预期条件', '实际读回结果', '核验状态', '核验时间', '证据位置'],
      ['V01', 'A01、D01', '不适用', '不适用', '离线工具无需账号及业务数据', '不适用', '—', '—']],
  };
  mkdirSync(dirname(file), { recursive: true });
  const script = `import json,sys
from xml.sax.saxutils import escape,quoteattr
from zipfile import ZipFile,ZIP_DEFLATED
sheets=json.load(sys.stdin)
options=json.loads(sys.argv[2])
ns='http://schemas.openxmlformats.org/spreadsheetml/2006/main'
rel='http://schemas.openxmlformats.org/officeDocument/2006/relationships'
def col(i):
 s=''
 while i:
  i,r=divmod(i-1,26);s=chr(65+r)+s
 return s
with ZipFile(sys.argv[1],'w',ZIP_DEFLATED) as z:
 z.writestr('[Content_Types].xml','<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'+''.join('<Override PartName="/xl/worksheets/sheet%d.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'%i for i in range(1,len(sheets)+1))+'</Types>')
 z.writestr('_rels/.rels','<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="'+rel+'/officeDocument" Target="xl/workbook.xml"/></Relationships>')
 z.writestr('xl/workbook.xml','<workbook xmlns="'+ns+'" xmlns:r="'+rel+'"><sheets>'+''.join('<sheet name='+quoteattr(name)+' sheetId="%d" r:id="rId%d"/>'%(i,i) for i,name in enumerate(sheets,1))+'</sheets></workbook>')
 z.writestr('xl/_rels/workbook.xml.rels','<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'+''.join('<Relationship Id="rId%d" Type="'%i+rel+'/worksheet" Target="worksheets/sheet%d.xml"/>'%i for i in range(1,len(sheets)+1))+'</Relationships>')
 for i,rows in enumerate(sheets.values(),1):
  dimension=options['dimension']
  dimension='' if dimension is None else '<dimension ref="'+('A1:A1' if dimension=='small' else 'A1:'+col(max(map(len,rows)))+str(len(rows)))+'"/>'
  xml='<worksheet xmlns="'+ns+'">'+dimension+'<sheetData>'
  for r,row in enumerate(rows,1):
   xml+='<row r="%d">'%r
   for c,v in enumerate(row,1):
    addr=col(c)+str(r)
    xml+=('<c r="'+addr+'"><v>'+str(v)+'</v></c>') if isinstance(v,int) else ('<c r="'+addr+'" t="inlineStr"><is><t>'+escape(str(v))+'</t></is></c>')
   xml+='</row>'
  if i==2 and options['overflowRow']:
   r=options['overflowRow'];xml+='<row r="%d"><c r="A%d" t="inlineStr"><is><t>overflow</t></is></c></row>'%(r,r)
  if i==2 and options['overflowColumn']:
   xml+='<row r="500"><c r="'+options['overflowColumn']+'500" t="inlineStr"><is><t>overflow</t></is></c></row>'
  z.writestr('xl/worksheets/sheet%d.xml'%i,xml+'</sheetData></worksheet>')`;
  const result = spawnSync('python3', ['-B', '-c', script, file, JSON.stringify({ dimension, overflowRow, overflowColumn })], { input: JSON.stringify(sheets), encoding: 'utf8' });
  if (result.status !== 0) throw new Error(result.stderr || result.error?.message);
}
