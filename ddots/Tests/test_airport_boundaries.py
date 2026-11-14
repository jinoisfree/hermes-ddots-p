"""관제 화면 경계 검사. CLI의 --root는 생성 공개판에도 같은 검사를 적용한다."""
import argparse
import ast
from pathlib import Path
import re
import shutil
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
def scanner_module(root):
    import importlib.util
    candidates = [Path(root).parent / 'hermes/plugin-store/team-kit/lib/hermes_facility/airport_boundaries.py',
                  Path(root).parent / 'plugins/team-kit/lib/hermes_facility/airport_boundaries.py',
                  Path.home() / '.hermes/plugin-store/team-kit/lib/hermes_facility/airport_boundaries.py']
    path = next((p for p in candidates if p.is_file()), None)
    if path is None:
        raise RuntimeError('시설 경계 스캐너를 찾을 수 없습니다.')
    spec = importlib.util.spec_from_file_location('ddots_airport_scanner', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def employee_words(root):
    """The facility owns reserved names and roster-word normalization."""
    import json
    import os
    scanner = scanner_module(root)
    home = Path(os.environ.get('HERMES_ROOT') or os.environ.get('HERMES_HOME') or Path.home() / '.hermes')
    if home.parent.name == 'profiles':
        home = home.parent.parent
    team = Path(os.environ.get('HERMES_TEAM_FILE') or home / 'owner/team.yaml')
    words = set()
    try:
        words.update(scanner.roster_words(scanner.read_source(team)))
    except ModuleNotFoundError:
        # The ordinary ddots test interpreter may not carry the gateway YAML dependency.
        import subprocess
        helper = Path.home() / '.hermes/bin/hermes-run'
        code = ("import importlib.util,json,sys; "
                "s=importlib.util.spec_from_file_location('airport',sys.argv[1]); "
                "m=importlib.util.module_from_spec(s); s.loader.exec_module(m); "
                "print(json.dumps(sorted(m.roster_words(m.read_source(sys.argv[2])))))")
        result = subprocess.run([str(helper), '-c', code, scanner.__file__, str(team)],
                                capture_output=True, text=True, check=True)
        words.update(json.loads(result.stdout))
    for example in (Path(root).parent / 'starter-templates/installation.json', Path(root).parent / 'installation.json'):
        if example.exists():
            words.update(scanner.roster_words({'agents': json.loads(example.read_text())['roles']}))
    return words


def employee_pattern(root):
    return scanner_module(root).word_pattern(employee_words(root))


OPERATIONAL_FUNCTIONS = ('installEditMenu', 'configureSlack', 'slackResult')
PROFILE_METADATA_ALLOWED = {'ProfileAvatar.swift': '사진 갱신 시각·색 메타데이터만 읽는다. 직원 정보 원본이 아니다.'}
STRING_START = re.compile(r'(\#*)("""|")')


def swift_literals_and_code(source):
    """주석(중첩 포함)을 버리고 문자열 조각과 선언 코드만 분리한다.

    Swift raw/multiline 문자열과 보간 내부의 문자열도 검사한다.
    """
    literals, code = [], list(source)

    def mask(start, end):
        for pos in range(start, end):
            if code[pos] != '\n':
                code[pos] = ' '

    def fragment(start, end):
        value = re.sub(r'\\u\{([0-9a-fA-F]+)\}', lambda m: chr(int(m[1], 16)), source[start:end])
        literals.append((source.count('\n', 0, start) + 1, value))

    def string(pos, match):
        start = pos
        hashes, quote = match.groups()
        closing, escape = quote + hashes, '\\' + hashes
        pos += len(match[0])
        part = pos
        while pos < len(source):
            if source.startswith(closing, pos):
                fragment(part, pos)
                pos += len(closing)
                mask(start, pos)
                return pos
            if source.startswith(escape + '(', pos):
                fragment(part, pos)
                pos = walk(pos + len(escape) + 1, 1)
                part = pos
            elif source.startswith(escape, pos):
                pos += len(escape) + 1
            else:
                pos += 1
        fragment(part, pos)
        mask(start, pos)
        return pos

    def walk(pos, depth=0):
        while pos < len(source):
            if source.startswith('//', pos):
                end = source.find('\n', pos)
                end = len(source) if end < 0 else end
                mask(pos, end)
                pos = end
            elif source.startswith('/*', pos):
                start, nesting = pos, 1
                pos += 2
                while pos < len(source) and nesting:
                    if source.startswith('/*', pos):
                        nesting += 1
                        pos += 2
                    elif source.startswith('*/', pos):
                        nesting -= 1
                        pos += 2
                    else:
                        pos += 1
                mask(start, pos)
            elif match := STRING_START.match(source, pos):
                pos = string(pos, match)
            else:
                char = source[pos]
                pos += 1
                if depth:
                    if char == '(':
                        depth += 1
                    elif char == ')':
                        depth -= 1
                        if not depth:
                            return pos
        return pos

    walk(0)
    return literals, ''.join(code)


def check_boundaries(root):
    root = Path(root)
    errors, used_metadata = [], set()
    sources = sorted((root / 'Sources').rglob('*.swift'))
    fixed_employee = employee_pattern(root)
    if not sources:
        errors.append('Sources: Swift 파일이 없습니다.')
    for filename, reason in PROFILE_METADATA_ALLOWED.items():
        if not reason.strip():
            errors.append(f'{filename}: 허용 이유가 비어 있습니다.')
        if not (root / 'Sources' / filename).is_file():
            errors.append(f'{filename}: 묵은 허용 항목입니다(파일 없음).')
    for path in sources:
        literals, code = swift_literals_and_code(path.read_text())
        smoke = path.match('*Smoke.swift')
        if smoke:
            for name in OPERATIONAL_FUNCTIONS:
                if match := re.search(r'\bfunc\s+' + re.escape(name) + r'\b', code):
                    line = code.count('\n', 0, match.start()) + 1
                    errors.append(f'{path.name}:{line}: 시험 제외 파일에 운영 함수 {name}가 있습니다.')
        for line, value in literals:
            if not smoke and fixed_employee and fixed_employee.search(value):
                errors.append(f'{path.name}:{line}: 직원 id·표시 이름을 코드에 고정했습니다.')
            for forbidden in ('team.yaml', '.starter/receipts', 'display_name:'):
                if forbidden in value:
                    errors.append(f'{path.name}:{line}: 직원 정보 직접 구성 문자열 {forbidden}')
            if 'profile.yaml' in value:
                if path.name in PROFILE_METADATA_ALLOWED:
                    used_metadata.add(path.name)
                else:
                    errors.append(f'{path.name}:{line}: profile.yaml은 사진 메타데이터 소유자에서만 허용합니다.')
    for name in PROFILE_METADATA_ALLOWED.keys() - used_metadata:
        errors.append(f'{name}: 묵은 profile.yaml 허용 항목입니다(문자열 없음).')
    for path in sorted((root / 'scripts').rglob('*')):
        if not path.is_file():
            continue
        if path.suffix == '.py':
            tree = ast.parse(path.read_text())
            docstrings = {id(n.body[0].value) for n in ast.walk(tree)
                          if isinstance(n, (ast.Module, ast.ClassDef, ast.FunctionDef, ast.AsyncFunctionDef))
                          and n.body and isinstance(n.body[0], ast.Expr)
                          and isinstance(n.body[0].value, ast.Constant)}
            literals = [(n.lineno, n.value) for n in ast.walk(tree)
                        if isinstance(n, ast.Constant) and isinstance(n.value, str) and id(n) not in docstrings]
        elif path.suffix in {'.sh', '.swift'}:
            literals, _ = swift_literals_and_code(path.read_text())
        else:
            continue
        for line, value in literals:
            if fixed_employee and fixed_employee.search(value):
                errors.append(f'{path.relative_to(root)}:{line}: 직원 id·표시 이름을 코드에 고정했습니다.')
    exporter = root / 'scripts/export_config.py'
    if not exporter.is_file():
        errors.append('scripts/export_config.py: 내보내기가 없습니다.')
        return errors
    tree = ast.parse(exporter.read_text())
    function = next(node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name == 'export')
    nodes = list(ast.walk(function))
    if not any(isinstance(n, ast.Constant) and n.value == 'hermes_facility.team_registry' for n in nodes) or not any(
            isinstance(n, ast.Call) and isinstance(n.func, ast.Attribute) and n.func.attr == 'roster' for n in nodes):
        errors.append('scripts/export_config.py:export: 시설 team_registry.roster 조회가 없습니다.')
    definitions = {}
    for node in nodes:
        if isinstance(node, ast.Assign):
            for target in node.targets:
                if isinstance(target, ast.Name):
                    definitions.setdefault(target.id, []).append(node.value)

    def origins(node, visited=frozenset()):
        if isinstance(node, ast.Call):
            if isinstance(node.func, ast.Attribute) and node.func.attr == 'roster':
                return {'roster'}
            if isinstance(node.func, ast.Name) and node.func.id == 'yaml_load':
                return {'config'}
        if isinstance(node, ast.Name):
            if node.id in visited:
                return set()
            return set().union(*(origins(value, visited | {node.id}) for value in definitions.get(node.id, [])))
        return set().union(*(origins(child, visited) for child in ast.iter_child_nodes(node)))

    for node in nodes:
        if isinstance(node, ast.Constant) and node.value == 'display_name':
            errors.append(f'scripts/export_config.py:{node.lineno}: members에 옛 display_name 출처를 사용했습니다.')
        if not (isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
                and isinstance(node.func.value, ast.Name) and node.func.value.id == 'members'
                and node.func.attr == 'append'):
            continue
        for argument in node.args:
            if isinstance(argument, ast.Call):
                for keyword in argument.keywords:
                    if keyword.arg in ('displayName', 'aliases') and origins(keyword.value) != {'roster'}:
                        errors.append(f'scripts/export_config.py:{keyword.lineno}: members의 {keyword.arg}은 시설 명부에서만 가져와야 합니다.')
    return errors


class AirportBoundaryTests(unittest.TestCase):
    def test_sources_respect_airport_boundaries(self):
        self.assertEqual(check_boundaries(ROOT), [])

    def copy_tree(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name) / 'ddots'
        root.mkdir()
        for example in (ROOT.parent / 'starter-templates/installation.json', ROOT.parent / 'installation.json'):
            if example.exists():
                shutil.copy2(example, root.parent / 'installation.json')
        shutil.copytree(ROOT / 'Sources', root / 'Sources')
        (root / 'scripts').mkdir()
        shutil.copy2(ROOT / 'scripts/export_config.py', root / 'scripts/export_config.py')
        return root

    def append(self, root, filename, text):
        with (root / 'Sources' / filename).open('a') as stream:
            stream.write('\n' + text + '\n')

    def test_moved_production_file_rejects_id_but_smoke_fixture_accepts_it(self):
        for value in sorted(employee_words(ROOT)):
            with self.subTest(value=value):
                root = self.copy_tree()
                production = root / 'Sources/SlackController.swift'
                original = production.read_text()
                self.append(root, production.name, f'let airportProbe = "{value}"')
                self.assertTrue(any('SlackController.swift:' in e and '직원 id' in e for e in check_boundaries(root)))
                production.write_text(original)
                self.append(root, 'SlackSetupSmoke.swift', f'let airportProbe = "{value}"')
                self.assertEqual(check_boundaries(root), [])

    def test_smoke_cannot_hide_operational_functions(self):
        root = self.copy_tree()
        path = root / 'Sources/SlackSetupSmoke.swift'
        original = path.read_text()
        for name in OPERATIONAL_FUNCTIONS:
            path.write_text(original + f'\nfunc {name}() {{}}\n')
            self.assertTrue(any(name in e and '운영 함수' in e for e in check_boundaries(root)))

    def test_direct_roster_strings_fail_even_in_smoke(self):
        for value in ('team.yaml', '.starter/receipts', 'display_name:', 'profile.yaml'):
            with self.subTest(value=value):
                root = self.copy_tree()
                self.append(root, 'SlackSetupSmoke.swift', f'let airportProbe = "{value}"')
                self.assertTrue(any('SlackSetupSmoke.swift:' in e for e in check_boundaries(root)))

    def test_stale_or_reasonless_exceptions_fail(self):
        from unittest.mock import patch
        root = self.copy_tree()
        with patch.dict(PROFILE_METADATA_ALLOWED, {'ProfileAvatar.swift': ''}):
            self.assertTrue(any('허용 이유' in e for e in check_boundaries(root)))
        path = root / 'Sources/ProfileAvatar.swift'
        path.write_text(path.read_text().replace('"profile.yaml"', '"removed"'))
        self.assertTrue(any('묵은 profile.yaml' in e for e in check_boundaries(root)))

    def test_exporter_old_member_sources_fail(self):
        root = self.copy_tree()
        path = root / 'scripts/export_config.py'
        path.write_text(path.read_text().replace("name = member['label'] or member['name']", "name = cfg.get('display_name') or raw.get('aliases')"))
        self.assertTrue(any('옛 display_name' in e for e in check_boundaries(root)))
        self.assertTrue(any('시설 명부에서만' in e for e in check_boundaries(root)))

    def test_swift_comments_raw_multiline_and_interpolated_strings(self):
        source = '// "work-assistant"\n/* outer /* "team.yaml" */ comment */\n' + r'''
let raw = ##"profile.yaml"##
let multiline = """display_name:
value"""
let interpolation = "name \(names["personal-secretary"])"
let escaped = "\u{74}iny-office"
'''
        literals, code = swift_literals_and_code(source)
        values = [value for _, value in literals]
        self.assertIn('profile.yaml', values)
        self.assertIn('personal-secretary', values)
        self.assertIn('work-assistant', values)
        self.assertTrue(any('display_name:' in value for value in values))
        self.assertNotIn('team.yaml', str(values))
        self.assertNotIn('work-assistant', code)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=ROOT)
    args = parser.parse_args()
    errors = check_boundaries(args.root)
    if errors:
        print('FAIL: 관제 화면 경계 위반\n' + '\n'.join(errors))
        return 1
    print('PASS: 관제 화면 경계 검사')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
