// Converts MovingAI benchmark files (.map + .scen) into the map.xml / task.xml
// format used by CCBS (see map.cpp / task.cpp for the reader).
//
// Usage:
//   ./movingai_converter <folder> [output_folder]
//
// <folder> must contain exactly one *.map file (MovingAI octile format) and
// one or more *.scen files (MovingAI scenario format, version 1). Writes
// map.xml and one <scen-name>.xml task file (with every agent from that
// scenario, in file order) per .scen file into [output_folder] (defaults to
// <folder>).
//
// Each task xml is written with exactly one <agent> element per line so that
// a shell script can take an N-agent prefix of a run with plain `head`.

#include <algorithm>
#include <cctype>
#include <dirent.h>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>
#include <sys/stat.h>
#include <vector>

struct GridMap
{
    int width = 0, height = 0;
    std::vector<std::string> rows; // '0' = free, '1' = obstacle
};

struct ScenAgent
{
    double start_i, start_j, goal_i, goal_j;
};

static std::string join_path(const std::string &dir, const std::string &name)
{
    if (!dir.empty() && dir.back() == '/')
        return dir + name;
    return dir + "/" + name;
}

static bool has_extension(const std::string &name, const std::string &ext)
{
    if (name.size() < ext.size())
        return false;
    return name.compare(name.size() - ext.size(), ext.size(), ext) == 0;
}

static std::string stem(const std::string &filename)
{
    size_t slash = filename.find_last_of('/');
    std::string base = (slash == std::string::npos) ? filename : filename.substr(slash + 1);
    size_t dot = base.find_last_of('.');
    return (dot == std::string::npos) ? base : base.substr(0, dot);
}

static bool list_dir(const std::string &folder, std::vector<std::string> &map_files, std::vector<std::string> &scen_files)
{
    DIR *dir = opendir(folder.c_str());
    if (!dir)
        return false;
    struct dirent *entry;
    while ((entry = readdir(dir)) != nullptr)
    {
        std::string name = entry->d_name;
        std::string full = join_path(folder, name);
        struct stat st;
        if (stat(full.c_str(), &st) != 0 || !S_ISREG(st.st_mode))
            continue;
        if (has_extension(name, ".map"))
            map_files.push_back(full);
        else if (has_extension(name, ".scen"))
            scen_files.push_back(full);
    }
    closedir(dir);
    std::sort(map_files.begin(), map_files.end());
    std::sort(scen_files.begin(), scen_files.end());
    return true;
}

static bool parse_map_file(const std::string &path, GridMap &map, std::string &err)
{
    std::ifstream f(path);
    if (!f)
    {
        err = "cannot open file";
        return false;
    }

    std::string line;
    bool have_height = false, have_width = false;
    while (std::getline(f, line))
    {
        std::istringstream iss(line);
        std::string key;
        iss >> key;
        if (key == "type")
        {
            continue;
        }
        else if (key == "height")
        {
            iss >> map.height;
            have_height = true;
        }
        else if (key == "width")
        {
            iss >> map.width;
            have_width = true;
        }
        else if (key == "map")
        {
            break;
        }
    }

    if (!have_height || !have_width)
    {
        err = "missing 'height' or 'width' header";
        return false;
    }

    map.rows.reserve(map.height);
    while (std::getline(f, line))
    {
        if (!line.empty() && line.back() == '\r')
            line.pop_back();
        if (line.empty())
            continue;
        if ((int)line.size() < map.width)
        {
            err = "row shorter than declared width";
            return false;
        }
        std::string row(map.width, '0');
        for (int j = 0; j < map.width; ++j)
        {
            char c = line[j];
            // MovingAI passable terrain: '.' ground, 'G' grass, 'S' swamp.
            // Everything else ('@','O','T','W', etc.) is treated as obstacle.
            bool passable = (c == '.' || c == 'G' || c == 'S');
            row[j] = passable ? '0' : '1';
        }
        map.rows.push_back(row);
        if ((int)map.rows.size() == map.height)
            break;
    }

    if ((int)map.rows.size() != map.height)
    {
        err = "fewer map rows than declared height";
        return false;
    }
    return true;
}

static bool write_map_xml(const std::string &path, const GridMap &map, std::string &err)
{
    std::ofstream f(path);
    if (!f)
    {
        err = "cannot open file for writing";
        return false;
    }
    f << "<?xml version=\"1.0\" ?>\n";
    f << "<root>\n";
    f << "\t<map>\n";
    f << "\t\t<width>" << map.width << "</width>\n";
    f << "\t\t<height>" << map.height << "</height>\n";
    f << "\t\t<grid>\n";
    for (const auto &row : map.rows)
        f << "\t\t\t<row>" << row << "</row>\n";
    f << "\t\t</grid>\n";
    f << "\t</map>\n";
    f << "</root>\n";
    return true;
}

// MovingAI scen (version 1) columns, whitespace separated:
//   bucket  map  map_width  map_height  start_x  start_y  goal_x  goal_y  optimal_length
// x is the column index, y is the row index, i.e. grid[y][x].
static bool parse_scen_file(const std::string &path, std::vector<ScenAgent> &agents, std::string &err)
{
    std::ifstream f(path);
    if (!f)
    {
        err = "cannot open file";
        return false;
    }

    std::string line;
    while (std::getline(f, line))
    {
        if (line.empty())
            continue;
        std::istringstream iss(line);
        std::string first;
        iss >> first;
        if (first == "version")
            continue;

        double bucket, map_width, map_height, start_x, start_y, goal_x, goal_y, optimal_length;
        std::string map_name;
        std::istringstream row(line);
        if (!(row >> bucket >> map_name >> map_width >> map_height >> start_x >> start_y >> goal_x >> goal_y >> optimal_length))
        {
            err = "malformed scenario line: " + line;
            return false;
        }

        ScenAgent a;
        a.start_i = start_y;
        a.start_j = start_x;
        a.goal_i = goal_y;
        a.goal_j = goal_x;
        agents.push_back(a);
    }
    return true;
}

static bool write_task_xml(const std::string &path, const std::vector<ScenAgent> &agents, std::string &err)
{
    std::ofstream f(path);
    if (!f)
    {
        err = "cannot open file for writing";
        return false;
    }
    f << "<?xml version=\"1.0\" ?>\n";
    f << "<root>\n";
    for (size_t i = 0; i < agents.size(); ++i)
    {
        const auto &a = agents[i];
        f << "<agent id=\"" << i << "\" start_i=\"" << a.start_i << "\" start_j=\"" << a.start_j
          << "\" goal_i=\"" << a.goal_i << "\" goal_j=\"" << a.goal_j << "\"/>\n";
    }
    f << "</root>\n";
    return true;
}

int main(int argc, char **argv)
{
    if (argc < 2)
    {
        std::cerr << "Usage: " << argv[0] << " <folder> [output_folder]\n"
                  << "  folder: contains exactly one *.map file and one or more *.scen files (MovingAI format)\n"
                  << "  output_folder: where to write map.xml and <scen>.xml (default: same as folder)\n";
        return 1;
    }
    std::string folder = argv[1];
    std::string out_folder = (argc > 2) ? argv[2] : folder;
    mkdir(out_folder.c_str(), 0755);

    std::vector<std::string> map_files, scen_files;
    if (!list_dir(folder, map_files, scen_files))
    {
        std::cerr << "Error: cannot open folder " << folder << "\n";
        return 1;
    }
    if (map_files.size() != 1)
    {
        std::cerr << "Error: expected exactly one .map file in " << folder << ", found " << map_files.size() << "\n";
        return 1;
    }
    if (scen_files.empty())
    {
        std::cerr << "Error: no .scen files found in " << folder << "\n";
        return 1;
    }

    GridMap map;
    std::string err;
    if (!parse_map_file(map_files[0], map, err))
    {
        std::cerr << "Error parsing " << map_files[0] << ": " << err << "\n";
        return 1;
    }
    std::string map_xml_path = join_path(out_folder, "map.xml");
    if (!write_map_xml(map_xml_path, map, err))
    {
        std::cerr << "Error writing " << map_xml_path << ": " << err << "\n";
        return 1;
    }
    std::cout << "Wrote " << map_xml_path << " (" << map.width << "x" << map.height << ")\n";

    int failures = 0;
    for (const auto &scen_path : scen_files)
    {
        std::vector<ScenAgent> agents;
        if (!parse_scen_file(scen_path, agents, err))
        {
            std::cerr << "Error parsing " << scen_path << ": " << err << "\n";
            ++failures;
            continue;
        }
        std::string task_xml_path = join_path(out_folder, stem(scen_path) + ".xml");
        if (!write_task_xml(task_xml_path, agents, err))
        {
            std::cerr << "Error writing " << task_xml_path << ": " << err << "\n";
            ++failures;
            continue;
        }
        std::cout << "Wrote " << task_xml_path << " (" << agents.size() << " agents)\n";
    }

    return failures == 0 ? 0 : 1;
}
