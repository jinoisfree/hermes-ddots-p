import importlib.util
import pathlib
import unittest

spec = importlib.util.spec_from_file_location('thread_digest', pathlib.Path(__file__).parents[1] / 'Resources/Helpers/thread_digest.py')
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)


def response(text='요약', reason='stop'):
    import json
    return {'choices': [{'finish_reason': reason, 'message': {'content': json.dumps({'summary': text})}}]}


class DigestTests(unittest.TestCase):
    def test_entire_conversation_and_no_tools(self):
        calls = []
        def call(**kwargs):
            calls.append(kwargs)
            return response('회의는 3시')
        result = helper.summarize([{'speaker': '나', 'body': '회의는 2시?'}, {'speaker': '비서', 'body': '3시로 변경'}], call)
        self.assertEqual(result, '회의는 3시')
        self.assertIn('회의는 2시?', calls[0]['messages'][1]['content'])
        self.assertIn('3시로 변경', calls[0]['messages'][1]['content'])
        self.assertIsNone(calls[0]['tools'])
        self.assertEqual(calls[0]['task'], 'compression')

    def test_large_conversation_combines_all_segments(self):
        calls = []
        def call(**kwargs):
            calls.append(kwargs['messages'][1]['content'])
            return response('구간' + str(len(calls)))
        result = helper.summarize([{'body': '처음' + '가' * 50000 + '마지막'}], call)
        self.assertIn('처음', calls[0])
        self.assertIn('마지막', calls[-2])
        self.assertIn('구간1', calls[-1])
        self.assertIn('구간3', calls[-1])
        self.assertEqual(result, '구간4')

    def test_refuses_truncation_and_reasoning(self):
        with self.assertRaises(ValueError):
            helper.content(response(reason='length'))
        with self.assertRaises(ValueError):
            helper.content({'choices': [{'message': {'reasoning_content': '비공개 추론'}}]})
        with self.assertRaises(ValueError):
            helper.summarize([{'body': 'x' * 96001}], lambda **_: response())
        with self.assertRaises(ValueError):
            helper.summarize([], lambda **_: response())

if __name__ == '__main__':
    unittest.main()
