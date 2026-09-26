from crosshire_apps.common.fingerprint import fingerprint, template


def test_template_strips_values():
    msg = ("Table 'main.s.t' not found at s3://bucket/a/b for bob@example.com "
           "id 3f2b8c9e-1a2b-4c3d-8e9f-001122334455 after 42 tries in /Workspace/Users/x/nb")
    assert template(msg) == "Table <str> not found at <path> for <email> id <uuid> after <num> tries in <path>"


def test_same_error_same_fingerprint():
    assert fingerprint("Lost task 1.0 in stage 7.0") == fingerprint("Lost task 3.0 in stage 12.0")
    assert fingerprint("disk full") != fingerprint("Java heap space")
    assert fingerprint(None) is None
