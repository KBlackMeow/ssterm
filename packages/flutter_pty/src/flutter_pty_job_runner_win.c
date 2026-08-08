#include <stdio.h>
#include <stdlib.h>
#include <wchar.h>
#include <Windows.h>

static void fail(const wchar_t *operation)
{
    fwprintf(stderr, L"[ssterm background] %ls failed (Win32 error %lu).\n", operation, GetLastError());
}

static int append(wchar_t **buffer, size_t *length, size_t *capacity, wchar_t value)
{
    if (*length + 2 > *capacity)
    {
        size_t next = *capacity == 0 ? 256 : *capacity * 2;
        wchar_t *grown = (wchar_t *)realloc(*buffer, next * sizeof(wchar_t));
        if (grown == NULL)
            return 0;
        *buffer = grown;
        *capacity = next;
    }
    (*buffer)[(*length)++] = value;
    (*buffer)[*length] = L'\0';
    return 1;
}

// Quotes one argv item according to CommandLineToArgvW parsing rules.
static int append_argument(wchar_t **buffer, size_t *length, size_t *capacity, const wchar_t *argument)
{
    size_t slashes = 0;
    int needs_quotes = argument[0] == L'\0';
    for (const wchar_t *p = argument; *p != L'\0'; p++)
    {
        if (*p == L' ' || *p == L'\t' || *p == L'"')
        {
            needs_quotes = 1;
            break;
        }
    }
    if (!needs_quotes)
    {
        for (const wchar_t *p = argument; *p != L'\0'; p++)
            if (!append(buffer, length, capacity, *p)) return 0;
        return 1;
    }
    if (!append(buffer, length, capacity, L'"'))
        return 0;
    for (const wchar_t *p = argument; *p != L'\0'; p++)
    {
        if (*p == L'\\')
        {
            slashes++;
            continue;
        }
        if (*p == L'"')
        {
            for (size_t i = 0; i < slashes * 2 + 1; i++)
                if (!append(buffer, length, capacity, L'\\')) return 0;
            if (!append(buffer, length, capacity, L'"')) return 0;
            slashes = 0;
            continue;
        }
        while (slashes-- > 0)
            if (!append(buffer, length, capacity, L'\\')) return 0;
        slashes = 0;
        if (!append(buffer, length, capacity, *p)) return 0;
    }
    for (size_t i = 0; i < slashes * 2; i++)
        if (!append(buffer, length, capacity, L'\\')) return 0;
    return append(buffer, length, capacity, L'"');
}

int wmain(int argc, wchar_t **argv)
{
    int command = 1;
    HANDLE parent = NULL;
    if (argc > 3 && wcscmp(argv[1], L"--parent-pid") == 0 && wcscmp(argv[3], L"--") == 0)
    {
        wchar_t *end = NULL;
        unsigned long parent_pid = wcstoul(argv[2], &end, 10);
        if (end == argv[2] || *end != L'\0' || parent_pid == 0)
        {
            fwprintf(stderr, L"Invalid parent PID.\n");
            return 2;
        }
        parent = OpenProcess(SYNCHRONIZE, FALSE, parent_pid);
        if (parent == NULL)
        {
            fail(L"OpenProcess(parent)");
            return 125;
        }
        command = 4;
    }
    else if (argc > 1 && wcscmp(argv[1], L"--") == 0)
        command = 2;
    if (command >= argc)
    {
        fwprintf(stderr, L"Usage: flutter_pty_job_runner [--parent-pid <pid>] -- <executable> [arguments...]\n");
        if (parent != NULL) CloseHandle(parent);
        return 2;
    }

    HANDLE job = CreateJobObjectW(NULL, NULL);
    if (job == NULL)
    {
        fail(L"CreateJobObjectW");
        if (parent != NULL) CloseHandle(parent);
        return 125;
    }
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION info = {0};
    info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    if (!SetInformationJobObject(job, JobObjectExtendedLimitInformation, &info, sizeof(info)))
    {
        fail(L"SetInformationJobObject");
        CloseHandle(job);
        if (parent != NULL) CloseHandle(parent);
        return 125;
    }

    wchar_t *command_line = NULL;
    size_t length = 0, capacity = 0;
    for (int i = command; i < argc; i++)
    {
        if (i != command && !append(&command_line, &length, &capacity, L' '))
            goto out_of_memory;
        if (!append_argument(&command_line, &length, &capacity, argv[i]))
            goto out_of_memory;
    }

    STARTUPINFOW startup = {0};
    startup.cb = sizeof(startup);
    PROCESS_INFORMATION process = {0};
    if (!CreateProcessW(argv[command], command_line, NULL, NULL, TRUE,
                        CREATE_SUSPENDED | CREATE_UNICODE_ENVIRONMENT,
                        NULL, NULL, &startup, &process))
    {
        fail(L"CreateProcessW");
        free(command_line);
        CloseHandle(job);
        if (parent != NULL) CloseHandle(parent);
        return 125;
    }
    free(command_line);

    if (!AssignProcessToJobObject(job, process.hProcess))
    {
        fail(L"AssignProcessToJobObject");
        TerminateProcess(process.hProcess, 125);
        CloseHandle(process.hThread);
        CloseHandle(process.hProcess);
        CloseHandle(job);
        if (parent != NULL) CloseHandle(parent);
        return 125;
    }
    if (ResumeThread(process.hThread) == (DWORD)-1)
    {
        fail(L"ResumeThread");
        CloseHandle(process.hThread);
        CloseHandle(process.hProcess);
        CloseHandle(job);
        if (parent != NULL) CloseHandle(parent);
        return 125;
    }

    HANDLE waits[2] = {process.hProcess, parent};
    DWORD wait = WaitForMultipleObjects(parent == NULL ? 1 : 2, waits, FALSE, INFINITE);
    if (wait == WAIT_FAILED)
    {
        fail(L"WaitForMultipleObjects");
        CloseHandle(process.hThread);
        CloseHandle(process.hProcess);
        CloseHandle(job);
        if (parent != NULL) CloseHandle(parent);
        return 125;
    }
    if (wait != WAIT_OBJECT_0 && (parent == NULL || wait != WAIT_OBJECT_0 + 1))
    {
        fwprintf(stderr, L"[ssterm background] WaitForMultipleObjects returned %lu.\n", wait);
        CloseHandle(process.hThread);
        CloseHandle(process.hProcess);
        CloseHandle(job);
        if (parent != NULL) CloseHandle(parent);
        return 125;
    }
    if (parent != NULL && wait == WAIT_OBJECT_0 + 1)
    {
        // The Flutter host died without being able to issue cancellation.
        // Closing this final Job handle activates KILL_ON_JOB_CLOSE.
        CloseHandle(process.hThread);
        CloseHandle(process.hProcess);
        CloseHandle(job);
        CloseHandle(parent);
        return 125;
    }
    DWORD exit_code = 125;
    if (!GetExitCodeProcess(process.hProcess, &exit_code))
        fail(L"GetExitCodeProcess");
    CloseHandle(process.hThread);
    CloseHandle(process.hProcess);
    CloseHandle(job);
    if (parent != NULL) CloseHandle(parent);
    return (int)exit_code;

out_of_memory:
    fwprintf(stderr, L"[ssterm background] Could not allocate Windows command line.\n");
    free(command_line);
    CloseHandle(job);
    if (parent != NULL) CloseHandle(parent);
    return 125;
}
